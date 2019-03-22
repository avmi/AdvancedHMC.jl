using Test, AdvancedHMC
using Statistics: mean, var, cov
include("common.jl")

θ_init = randn(D)
ϵ = 0.02
n_steps = 20
n_samples = 100_000
n_adapts = 1_000

@testset "HMC and NUTS" begin
    temp = randn(D,100)
    for metric in [UnitEuclideanMetric(θ_init), DiagEuclideanMetric(θ_init, vec(var(temp; dims=2))), DenseEuclideanMetric(θ_init, cov(temp'))]
        h = Hamiltonian(metric, logπ, ∂logπ∂θ)
        for prop in [TakeLastProposal(Leapfrog(ϵ), n_steps), SliceNUTS(Leapfrog(find_good_eps(h, θ_init)))]
            samples = AdvancedHMC.sample(h, prop, θ_init, n_samples; verbose=false)
            @test mean(samples) ≈ zeros(D) atol=RNDATOL
            for adapter in [DualAveraging(0.8, prop.integrator.ϵ), PreConditioner(metric)]
                samples = AdvancedHMC.sample(h, prop, θ_init, n_samples, adapter, n_adapts; verbose=false)
                @test mean(samples) ≈ zeros(D) atol=RNDATOL
            end
        end
    end
end
