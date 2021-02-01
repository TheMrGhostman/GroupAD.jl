using Flux
using ConditionalDists
using GenerativeModels
import GenerativeModels: VAE
using ValueHistories
using MLDataPattern: RandomBatches
using Distributions
using DistributionsAD
using StatsBase
using Random

"""
	safe_softplus(x::T)

Safe version of softplus.	
"""
safe_softplus(x::T) where T  = softplus(x) + T(0.000001)

"""
	init_vamp(pseudoinput_mean,k::Int)

Initializes the VAMP prior from a mean vector and number of components.
"""
function init_vamp(pseudoinput_mean, k::Int)
	T = eltype(pseudoinput_mean)
	pseudoinputs = T(1) .* randn(T, size(pseudoinput_mean)[1:end-1]..., k) .+ pseudoinput_mean
	VAMP(pseudoinputs)
end

"""
	vae_constructor(;idim::Int=1, zdim::Int=1, activation = "relu", hdim=128, nlayers::Int=3, 
		init_seed=nothing, prior="normal", pseudoinput_mean=nothing, k=1, kwargs...)

Constructs a classical variational autoencoder.

# Arguments
	- `idim::Int`: input dimension.
	- `zdim::Int`: latent space dimension.
	- `activation::String="relu"`: activation function.
	- `hdim::Int=128`: size of hidden dimension.
	- `nlayers::Int=3`: number of decoder/encoder layers, must be >= 3. 
	- `init_seed=nothing`: seed to initialize weights.
	- `prior="normal"`: one of ["normal", "vamp"].
	- `pseudoinput_mean=nothing`: mean of data used to initialize the VAMP prior.
	- `k::Int=1`: number of VAMP components. 
	- `var="scalar"`: decoder covariance computation, one of ["scalar", "diag"].
"""
function vae_constructor(;idim::Int=1, zdim::Int=1, activation="relu", hdim=128, nlayers::Int=3, 
	init_seed=nothing, prior="normal", pseudoinput_mean=nothing, k=1, var="scalar", kwargs...)
	(nlayers < 3) ? error("Less than 3 layers are not supported") : nothing
	
	# if seed is given, set it
	(init_seed != nothing) ? Random.seed!(init_seed) : nothing
	
	# construct the model
	# encoder - diagonal covariance
	encoder_map = Chain(
		build_mlp(idim, hdim, hdim, nlayers-1, activation=activation)...,
		ConditionalDists.SplitLayer(hdim, [zdim, zdim], [identity, safe_softplus])
		)
	encoder = ConditionalMvNormal(encoder_map)
	
	# decoder - we will optimize only a shared scalar variance for all dimensions
	if var=="scalar"
		decoder_map = Chain(
			build_mlp(zdim, hdim, hdim, nlayers-1, activation=activation)...,
			ConditionalDists.SplitLayer(hdim, [idim, 1], [identity, safe_softplus])
			)
	else
		decoder_map = Chain(
				build_mlp(zdim, hdim, hdim, nlayers-1, activation=activation)...,
				ConditionalDists.SplitLayer(hdim, [idim, idim], [identity, safe_softplus])
				)
	end
	decoder = ConditionalMvNormal(decoder_map)

	# prior
	if prior == "normal"
		prior_arg = zdim
	elseif prior == "vamp"
		(pseudoinput_mean === nothing) ? error("if `prior=vamp`, supply pseudoinput array") : nothing
		prior_arg = init_vamp(pseudoinput_mean, k)
	end

	# reset seed
	(init_seed !== nothing) ? Random.seed!() : nothing

	# get the vanilla VAE
	model = VAE(prior_arg, encoder, decoder)
end

"""
	StatsBase.fit!(model::VAE, data::Tuple, loss::Function; max_train_time=82800, lr=0.001, 
		batchsize=64, patience=30, check_interval::Int=10, kwargs...)
"""
function StatsBase.fit!(model::VAE, data::Tuple, loss::Function; max_iters=10000, max_train_time=82800, 
	lr=0.001, batchsize=64, patience=30, check_interval::Int=10, kwargs...)
	history = MVHistory()
	opt = ADAM(lr)

	tr_model = deepcopy(model)
	ps = Flux.params(tr_model)
	_patience = patience

	tr_x = data[1][1]
	# i know this could be done generally for all sizes but it is very ugly afaik
	if ndims(tr_x) == 2
		val_x = data[2][1][:,data[2][2] .== 0]
	elseif ndims(tr_x) == 4
		val_x = data[2][1][:,:,:,data[2][2] .== 0]
	else
		error("not implemented for other than 2D and 4D data")
	end
	val_N = size(val_x,ndims(val_x))

	# on large datasets, batching loss is faster
	best_val_loss = Inf
	i = 1
	start_time = time() # end the training loop after 23hrs
	for batch in RandomBatches(tr_x, batchsize)
		# batch loss
		batch_loss = 0f0
		gs = gradient(() -> begin 
			batch_loss = loss(tr_model,batch)
		end, ps)
	 	Flux.update!(opt, ps, gs)

		push!(history, :training_loss, i, batch_loss)
		if mod(i, check_interval) == 0
			
			# validation/early stopping
			val_loss = (val_N > 5000) ? loss(tr_model, val_x, 256) : loss(tr_model, val_x)
			
			@info "$i - loss: $(batch_loss) (batch) | $(val_loss) (validation)"
				
			if isnan(val_loss) || isnan(batch_loss)
				error("Encountered invalid values in loss function.")
			end

			push!(history, :validation_likelihood, i, val_loss)
			
			if val_loss < best_val_loss
				best_val_loss = val_loss
				_patience = patience

				# this should save the model at least once
				# when the validation loss is decreasing 
				model = deepcopy(tr_model)
			else # else stop if the model has not improved for `patience` iterations
				_patience -= 1
				if _patience == 0
					@info "Stopped training after $(i) iterations."
					break
				end
			end
		end
		if (time() - start_time > max_train_time) | (i > max_iters) # stop early if time is running out
			model = deepcopy(tr_model)
			@info "Stopped training after $(i) iterations, $((time() - start_time)/3600) hours."
			break
		end
		i += 1
	end
	# again, this is not optimal, the model should be passed by reference and only the reference should be edited
	(history=history, iterations=i, model=model, npars=sum(map(p->length(p), Flux.params(model))))
end
