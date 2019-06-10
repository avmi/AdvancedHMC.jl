###
### Preconditioning matrix adaptors.
###

abstract type AbstractPreconditioner <: AbstractAdaptor end

####
#### Robust online (co-)variance estimators.
####

abstract type VarEstimator{T} end

# NOTE: this naive variance estimator is used only in testing
mutable struct NaiveVar{T} <: VarEstimator{T}
    n :: Int
    S :: Vector{Vector{T}}
end

NaiveVar(::Type{T}=Float64) where {T} = NaiveVar(0, Vector{Vector{T}}())
NaiveVar(::Type{T}, ::Int) where {T} = NaiveVar(T)
NaiveVar(::Int) = NaiveVar(Float64)

function add_sample!(nc::NaiveVar, s::AbstractVector)
    nc.n += 1
    push!(nc.S, s)
end

function reset!(nc::NaiveVar{T}) where {T<:AbstractFloat}
    nc.n = 0
    nc.S = Vector{Vector{T}}()
end

function get_var(nc::NaiveVar{T}) where {T<:AbstractFloat}
    @assert nc.n >= 2 "Cannot get variance with only one sample"
    return Statistics.var(nc.S)
end

# Ref： https://github.com/stan-dev/math/blob/develop/stan/math/prim/mat/fun/welford_var_estimator.hpp
mutable struct WelfordVar{T<:AbstractFloat, AT<:AbstractVector{T}} <: VarEstimator{T}
    n :: Int
    μ :: AT
    M :: AT
end

WelfordVar(::Type{T}, d::Int) where {T} = WelfordVar(0, zeros(T, d), zeros(T, d))
WelfordVar(d::Int) = WelfordVar(Float64, d)

function reset!(wv::WelfordVar{T, AT}) where {T<:AbstractFloat, AT<:AbstractVector{T}}
    wv.n = 0
    wv.μ .= zero(T)
    wv.M .= zero(T)
end

function add_sample!(wv::WelfordVar, s::AbstractVector)
    wv.n += 1
    δ = s .- wv.μ
    wv.μ .+= δ ./ wv.n
    wv.M .+= δ .* (s .- wv.μ)
end

# https://github.com/stan-dev/stan/blob/develop/src/stan/mcmc/var_adaptation.hpp
function get_var(wv::WelfordVar{T, AT}) where {T<:AbstractFloat, AT<:AbstractVector{T}}
    n, M = wv.n, wv.M
    @assert n >= 2 "Cannot get covariance with only one sample"
    return (n*one(T) / ((n + 5) * (n - 1))) .* M .+ T(1e-3) * (5*one(T) / (n + 5))
end

abstract type CovEstimator{T} end

# NOTE: this naive covariance estimator is used only in testing
mutable struct NaiveCov{T} <: CovEstimator{T}
    n :: Int
    S :: Vector{Vector{T}}
end
NaiveCov(::Type{T}=Float64) where {T} = NaiveCov(0, Vector{Vector{T}}())

function add_sample!(nc::NaiveCov, s::AbstractVector)
    nc.n += 1
    push!(nc.S, s)
end

function reset!(nc::NaiveCov{T}) where {T<:AbstractFloat}
    nc.n = 0
    nc.S = Vector{Vector{T}}()
end

function get_cov(nc::NaiveCov{T})::Matrix{T} where {T<:AbstractFloat}
    @assert nc.n >= 2 "Cannot get covariance with only one sample"
    return Statistics.cov(nc.S)
end

# Ref: https://github.com/stan-dev/math/blob/develop/stan/math/prim/mat/fun/welford_covar_estimator.hpp
mutable struct WelfordCov{T<:AbstractFloat} <: CovEstimator{T}
    n :: Int
    μ :: Vector{T}
    M :: Matrix{T}
    δ :: Vector{T} # temporary
end

function WelfordCov(::Type{T}, d::Int) where {T}
    return WelfordCov(0, zeros(T, d), zeros(T, d, d), zeros(T, d))
end
WelfordCov(d::Int) = WelfordCov(Float64, d)

function reset!(wc::WelfordCov{T}) where {T<:AbstractFloat}
    wc.n = 0
    wc.μ .= zero(T)
    wc.M .= zero(T)
end

function add_sample!(wc::WelfordCov, s::AbstractVector)
    wc.n += 1
    δ = s .- wc.μ
    wc.μ .+= δ ./ wc.n
    wc.M .+= (s .- wc.μ) * δ'
end
# Ref: https://github.com/stan-dev/stan/blob/develop/src/stan/mcmc/covar_adaptation.hpp
function get_cov(wc::WelfordCov{T}) where {T<:AbstractFloat}
    n, M = wc.n, wc.M
    @assert n >= 2 "Cannot get variance with only one sample"
    return (n*one(T) / ((n + 5) * (n - 1))) .* M + T(1e-3) * (5*one(T) / (n + 5)) * LinearAlgebra.I
end

####
#### Preconditioning matrix adaption implementation.
####

# Unit
struct UnitPreconditioner{T} <: AbstractPreconditioner end
UnitPreconditioner(::Type{T} = Float64) where {T} = UnitPreconditioner{T}()

string(::UnitPreconditioner) = "I"
reset!(::UnitPreconditioner) = nothing
getM⁻¹(dpc::UnitPreconditioner{T}) where {T} = one(T)
adapt!(
    ::UnitPreconditioner,
    ::AbstractVector{<:Real},
    ::AbstractFloat;
    is_update::Bool=true
) = nothing


mutable struct DiagPreconditioner{T<:Real, AT<:AbstractVector{T}, TEst <: VarEstimator{T}} <: AbstractPreconditioner
    n_min   :: Int
    ve  :: TEst
    var :: AT
end

# Diagonal
DiagPreconditioner(d::Int, n_min::Int=10) = DiagPreconditioner(Float64, d, n_min)
function DiagPreconditioner(::Type{T}, d::Int, n_min::Int=10) where {T}
    ve = WelfordVar(T, d)
    return DiagPreconditioner(n_min, ve, Vector(ones(T, d)))
end

string(dpc::DiagPreconditioner) = string(dpc.var)
reset!(dpc::DiagPreconditioner) = reset!(dpc.ve)
getM⁻¹(dpc::DiagPreconditioner) = dpc.var

function adapt!(
    dpc::DiagPreconditioner,
    θ::AbstractVector{T},
    α::AbstractFloat;
    is_update::Bool=true
) where {T<:Real}
    resize!(dpc, θ)
    add_sample!(dpc.ve, θ)
    if dpc.ve.n >= dpc.n_min && is_update
        # Can be made inplace
        dpc.var .= get_var(dpc.ve)
    end
end

# Dense
mutable struct DensePreconditioner{T<:AbstractFloat, TEst <: CovEstimator{T}} <: AbstractPreconditioner
    n_min :: Int
    ce    :: TEst
    covar :: Matrix{T}
end

DensePreconditioner(d::Integer, n_min::Int=10) = DensePreconditioner(Float64, d, n_min)
function DensePreconditioner(::Type{T}, d::Integer, n_min::Int=10) where {T}
    ce = WelfordCov(T, d)
    # TODO: take use of the line below when we have an interface to set which pre-conditioner to use
    # ce = NaiveCov(T)
    return DensePreconditioner(n_min, ce, LinearAlgebra.diagm(0 => ones(T, d)))
end

string(dpc::DensePreconditioner) = string(LinearAlgebra.diag(dpc.covar))
reset!(dpc::DensePreconditioner) = reset!(dpc.ce)
getM⁻¹(dpc::DensePreconditioner) = dpc.covar

function adapt!(
    dpc::DensePreconditioner,
    θ::AbstractVector{T},
    α::AbstractFloat;
    is_update::Bool=true
) where {T<:AbstractFloat}
    resize!(dpc, θ)
    add_sample!(dpc.ce, θ)
    if dpc.ce.n >= dpc.n_min && is_update
        # Can be made inplace
        dpc.covar .= get_cov(dpc.ce)
    end
end

# Resize pre-conditioner if necessary.
Base.resize!(
    pc::UnitPreconditioner,
    θ::AbstractVector{T}
) where {T<:Real} = nothing
function Base.resize!(
    dpc::DiagPreconditioner,
    θ::AbstractVector{T}
) where {T<:Real}
    if length(θ) != length(dpc.var)
        @assert dpc.ve.n == 0 "Cannot resize a var estimator when it contains samples."
        dpc.ve = WelfordVar(T, length(θ))
        dpc.var = zeros(T, length(θ))
    end
end
function Base.resize!(
    dpc::DensePreconditioner,
    θ::AbstractVector{T}
) where {T<:Real}
    if length(θ) != size(dpc.covar,1)
        @assert dpc.ce.n == 0 "Cannot resize a var estimator when it contains samples."
        dpc.ce = WelfordCov(T, length(θ))
        dpc.covar = LinearAlgebra.diagm(0 => ones(T, length(θ)))
    end
end

####
#### Preconditioning mass matrix.
####

abstract type AbstractMetric end

struct UnitEuclideanMetric{T} <: AbstractMetric
    dim::Int
end
UnitEuclideanMetric(::Type{T}, dim::Int) where {T} = UnitEuclideanMetric{T}(dim)
UnitEuclideanMetric(dim::Int) = UnitEuclideanMetric(Float64, dim)

# Create a `UnitEuclideanMetric`; required for an unified interface
(ue::UnitEuclideanMetric{T})(::Nothing) where {T} = UnitEuclideanMetric(T, ue.dim)

Base.length(e::UnitEuclideanMetric) = e.dim
(e::UnitEuclideanMetric{T})(dim::Int) where {T} = UnitEuclideanMetric(T, dim)
(e::UnitEuclideanMetric{T})(::AbstractFloat) where {T} = UnitEuclideanMetric(T, e.dim)


function _string_diag(d, n_chars::Int=32) :: String
    s_diag = string(d)
    l = length(s_diag)
    s_dots = " ..."
    n_diag_chars = n_chars - length(s_dots)
    return s_diag[1:min(n_diag_chars,end)] * (l > n_diag_chars ? s_dots : "")
end

Base.show(io::IO, uem::UnitEuclideanMetric) = print(io, _string_diag(ones(uem.dim)))

struct DiagEuclideanMetric{T, A<:AbstractVector{T}} <: AbstractMetric
    # Diagnal of the inverse of the mass matrix
    M⁻¹     ::  A
    # Sqare root of the inverse of the mass matrix
    sqrtM⁻¹ ::  A
    # Pre-allocation for intermediate variables
    _temp   ::  A
end

function DiagEuclideanMetric(M⁻¹::AbstractVector{T}) where {T<:Real}
    return DiagEuclideanMetric(M⁻¹, sqrt.(M⁻¹), Vector{T}(undef, size(M⁻¹, 1)))
end
DiagEuclideanMetric(::Type{T}, D::Int) where {T} = DiagEuclideanMetric(ones(T, D))
DiagEuclideanMetric(D::Int) = DiagEuclideanMetric(Float64, D)

# Create a `DiagEuclideanMetric` with a new `M⁻¹`
(dem::DiagEuclideanMetric)(M⁻¹::AbstractVector{<:Real}) = DiagEuclideanMetric(M⁻¹)

Base.length(e::DiagEuclideanMetric) = size(e.M⁻¹, 1)
(e::DiagEuclideanMetric{T})(dim::Int) where {T} = DiagEuclideanMetric(T, dim)

Base.show(io::IO, dem::DiagEuclideanMetric) = print(io, _string_diag(dem.M⁻¹))

function Base.getproperty(dem::DiagEuclideanMetric, d::Symbol)
    return d === :dim ? size(getfield(dem, :M⁻¹), 1) : getfield(dem, d)
end


struct DenseEuclideanMetric{
    T,
    AV<:AbstractVector{T},
    AM<:AbstractMatrix{T},
    TcholM⁻¹<:UpperTriangular{T},
} <: AbstractMetric
    # Inverse of the mass matrix
    M⁻¹::AM
    # U of the Cholesky decomposition of the mass matrix
    cholM⁻¹::TcholM⁻¹
    # Pre-allocation for intermediate variables
    _temp::AV
end

function DenseEuclideanMetric(M⁻¹::AbstractMatrix{T}) where {T<:Real}
    _temp = Vector{T}(undef, size(M⁻¹, 1))
    return DenseEuclideanMetric(M⁻¹, cholesky(Symmetric(M⁻¹)).U, _temp)
end
DenseEuclideanMetric(::Type{T}, D::Int) where {T} = DenseEuclideanMetric(Matrix{T}(I, D, D))
DenseEuclideanMetric(D::Int) = DenseEuclideanMetric(Float64, D)

# Create a `DenseEuclideanMetric` with a new `M⁻¹`
(dem::DenseEuclideanMetric)(M⁻¹::AbstractMatrix{<:Real}) = DenseEuclideanMetric(M⁻¹)

Base.length(e::DenseEuclideanMetric) = size(e.M⁻¹, 1)
(e::DenseEuclideanMetric{T})(dim::Int) where {T} = DenseEuclideanMetric(T, dim)

Base.show(io::IO, dem::DenseEuclideanMetric) = print(io, _string_diag(diag(dem.M⁻¹)))

function Base.getproperty(dem::DenseEuclideanMetric, d::Symbol)
    return d === :dim ? size(getfield(dem, :M⁻¹), 1) : getfield(dem, d)
end

# `rand` functions for `metric` types.
function Base.rand(
    rng::AbstractRNG,
    metric::UnitEuclideanMetric{T}
) where {T}
    r = randn(rng, T, metric.dim)
    return r
end

function Base.rand(
    rng::AbstractRNG,
    metric::DiagEuclideanMetric{T}
) where {T}
    r = randn(rng, T, metric.dim)
    r ./= metric.sqrtM⁻¹
    return r
end

function Base.rand(
    rng::AbstractRNG,
    metric::DenseEuclideanMetric{T}
) where {T}
    r = randn(rng, T, metric.dim)
    ldiv!(metric.cholM⁻¹, r)
    return r
end

Base.rand(metric::AbstractMetric) = rand(GLOBAL_RNG, metric)

####
#### Preconditioner constructors
####

function Preconditioner(::UnitEuclideanMetric{T}) where {T}
    return UnitPreconditioner(T)
end

function Preconditioner(m::DiagEuclideanMetric{T}) where {T}
    return DiagPreconditioner(T, m.dim)
end

function Preconditioner(m::DenseEuclideanMetric{T}) where {T}
    return DensePreconditioner(T, m.dim)
end

Preconditioner(m, dim::Integer=2) = Preconditioner(Float64, m, dim)
function Preconditioner(::Type{T}, m, dim::Integer=2) where {T <: AbstractFloat}
    if m == UnitEuclideanMetric
        pc = UnitPreconditioner(T)
    elseif m == DiagEuclideanMetric
        pc = DiagPreconditioner(T, dim)
    elseif m == DenseEuclideanMetric
        pc = DensePreconditioner(T, dim)
    else
        @error "m needs to be one of [UnitEuclideanMetric, DiagEuclideanMetric, DenseEuclideanMetric]"
    end
    return pc
end
