module NARXEFEAgents

using Optim
using ForwardDiff
using Distributions
using SpecialFunctions
using LinearAlgebra

using .location_scale_tdist
using .mv_normal_gamma

export NARXEFEAgent, update!, predictions, posterior_predictive, pol, crossentropy, mutualinfo,
    minimizeEFE, backshift, update_goals!, EFE, EFE_balance

mutable struct NARXEFEAgent
    """
    Active inference agent based on a Nonlinear Auto-Regressive eXogenous model.

    Parameters are inferred through Bayesian filtering and controls through expected free energy minimization.
    """

    ybuffer         ::Vector{Float64}
    ubuffer         ::Vector{Float64}
    delay_inp       ::Integer
    delay_out       ::Integer
    pol_degree      ::Integer
    zero_order      ::Bool
    order           ::Integer

    μ               ::Vector{Float64}   # Coefficients mean
    Λ               ::Matrix{Float64}   # Coefficients precision
    α               ::Float64           # Likelihood precision shape
    β               ::Float64           # Likelihood precision rate
    η               ::Float64           # Control prior precision

    goals           ::Union{Distribution{Univariate, Continuous}, Vector}
    thorizon        ::Integer
    num_iters       ::Integer

    free_energy     ::Float64

    function NARXEFEAgent(coefficients_mean,
                       coefficients_precision,
                       noise_shape,
                       noise_rate; 
                       goal_prior=Normal(0.0, 1.0),
                       delay_inp::Integer=1, 
                       delay_out::Integer=1, 
                       pol_degree::Integer=1,
                       zero_order::Bool=true,
                       time_horizon::Integer=1,
                       num_iters::Integer=10,
                       control_prior_precision::Float64=0.0)

        ybuffer = zeros(delay_out)
        ubuffer = zeros(delay_inp+1)

        order = size(pol(zeros(1 + delay_inp + delay_out), degree=pol_degree, zero_order=zero_order),1)
        if order != length(coefficients_mean) 
            error("Dimensionality of coefficients and model order do not match.")
        end

        free_energy = Inf

        return new(ybuffer,
                   ubuffer,
                   delay_inp,
                   delay_out,
                   pol_degree,
                   zero_order,
                   order,
                   coefficients_mean,
                   coefficients_precision,
                   noise_shape,
                   noise_rate,
                   control_prior_precision,
                   goal_prior,
                   time_horizon,
                   num_iters,
                   free_energy)
    end
end

function pol(x; degree::Integer = 1, zero_order=true)
    "Polynomial basis expansion"
    if zero_order
        return cat([1.0; [x.^d for d in 1:degree]]...,dims=1)
    else 
        return cat([x.^d for d in 1:degree]...,dims=1)
    end    
end

function update!(agent::NARXEFEAgent, y::Float64, u::Float64)
    "Update parameters of posterior distributions."

    agent.ubuffer = backshift(agent.ubuffer, u)
    ϕ = pol([agent.ybuffer; agent.ubuffer], degree=agent.pol_degree, zero_order=agent.zero_order)

    μ0 = agent.μ
    Λ0 = agent.Λ
    α0 = agent.α
    β0 = agent.β

    agent.μ = inv(ϕ*ϕ' + Λ0)*(ϕ*y + Λ0*μ0)
    agent.Λ = ϕ*ϕ' + Λ0
    agent.α = α0 + 1/2
    agent.β = β0 + 1/2*(y^2 + μ0'*Λ0*μ0 - (ϕ*y + Λ0*μ0)'*inv(ϕ*ϕ' + Λ0)*(ϕ*y + Λ0*μ0))

    agent.ybuffer = backshift(agent.ybuffer, y)

    agent.free_energy = -log_marginal_likelihood(agent, (μ0, Λ0, α0, β0))
end

function params(agent::NARXEFEAgent)
    "Return parameters of agent"
    return agent.μ, agent.Λ, agent.α, agent.β
end

function marginal_likelihood(agent::NARXEFEAgent, prior_params)
    "Marginal likelihood (aka model evidence) of generative model." 

    μn, Λn, αn, βn = params(agent)
    μ0, Λ0, α0, β0 = prior_params

    return (det(Λn)^(-1/2)*gamma(αn)*βn^αn)/(det(Λ0)^(-1/2)*gamma(α0)*β0^α0) * (2π)^(-1/2)
end

function log_marginal_likelihood(agent::NARXEFEAgent, prior_params)
    "Log-marginal likelihood (aka log model evidence) of generative model."
    μn, Λn, αn, βn = params(agent)
    μ0, Λ0, α0, β0 = prior_params

    return -1/2*logdet(Λn) + log(gamma(αn)) + αn*log(βn) -(-1/2*logdet(Λ0) +log(gamma(α0)) + α0*log(β0)) -1/2*log(2π)
end

function posterior_predictive(agent::NARXEFEAgent, ϕ_t)
    "Posterior predictive distribution is location-scale t-distributed"

    ν_t = 2*agent.α
    m_t = dot(agent.μ, ϕ_t)
    s2_t = agent.β/agent.α*(1 + ϕ_t'*inv(agent.Λ)*ϕ_t)

    return ν_t, m_t, s2_t
end

function predictions(agent::NARXEFEAgent, controls; time_horizon=1)
    "Generate predictions of future observations for a given time horizon."
    
    m_y = zeros(time_horizon)
    v_y = zeros(time_horizon)

    ybuffer = agent.ybuffer
    ubuffer = agent.ubuffer
    
    for t in 1:time_horizon
        
        # Update control buffer
        ubuffer = backshift(ubuffer, controls[t])
        ϕ_t = pol([ybuffer; ubuffer], degree=agent.pol_degree, zero_order=agent.zero_order)

        ν_t, m_t, s2_t = posterior_predictive(agent, ϕ_t)
        
        # Prediction
        m_y[t] = m_t
        v_y[t] = s2_t * ν_t/(ν_t - 2)
        
        # Update previous 
        ybuffer = backshift(ybuffer, m_y[t])
        
    end
    return m_y, v_y
end

function mutualinfo(agent::NARXEFEAgent, ϕ_t)
    "Mutual information between parameters and posterior predictive (constant terms dropped)"
    return 1/2*log(1 + ϕ_t'*inv(agent.Λ)*ϕ_t)
end

function mutualinfo(agent::NARXEFEAgent, ybuffer, ubuffer, control)
    "Mutual information between parameters and posterior predictive (constant terms dropped)"

    ubuffer = backshift(ubuffer, control)
    ϕ_t = pol([ybuffer; ubuffer], degree=agent.pol_degree, zero_order=agent.zero_order)

    return 1/2*log(1 + ϕ_t'*inv(agent.Λ)*ϕ_t)
end

function crossentropy(agent::NARXEFEAgent, goal::Distribution{Univariate, Continuous}, m_pred, v_pred)
    "Cross-entropy between posterior predictive and goal prior (constant terms dropped)"  
    return ( v_pred + (m_pred - mean(goal))^2 ) / ( 2var(goal) )
    # return (m_pred - mean(goal))^2/(2var(goal))
end 

function crossentropy(agent::NARXEFEAgent, ybuffer, ubuffer, goal::Distribution{Univariate, Continuous}, control)
    "Cross-entropy between posterior predictive and goal prior (constant terms dropped)"  
    
    ubuffer = backshift(ubuffer, control)
    ϕ_t = pol([ybuffer; ubuffer], degree=agent.pol_degree, zero_order=agent.zero_order)
    ν_t, m_t, s2_t = posterior_predictive(agent, ϕ_t)
    
    return ( s2_t * ν_t/(ν_t - 2) + (m_t - mean(goal))^2 ) / ( 2var(goal) )
end 

function EFE(agent::NARXEFEAgent, ybuffer, ubuffer, goal::Distribution{Univariate, Continuous}, control)
    "Compute Expected Free Energy for a single control"
    return crossentropy(agent,ybuffer,ubuffer,goal,control) -mutualinfo(agent,ybuffer,ubuffer,control) +agent.η/2*control^2
end

function EFE(agent::NARXEFEAgent, goals, controls)
    "Expected Free Energy function"

    ybuffer = agent.ybuffer
    ubuffer = agent.ubuffer
    
    J = 0
    for t in 1:agent.thorizon
        
        # Update control buffer
        ubuffer = backshift(ubuffer, controls[t])
        ϕ_t = pol([ybuffer; ubuffer], degree=agent.pol_degree, zero_order=agent.zero_order)

        # Prediction
        ν_t, m_t, s2_t = posterior_predictive(agent, ϕ_t)
        
        m_y = m_t
        v_y = s2_t * ν_t/(ν_t - 2)
        
        # Accumulate EFE
        J += crossentropy(agent, goals[t], m_y, v_y) - mutualinfo(agent, ϕ_t) + agent.η/2*controls[t]^2
        
        # Update previous 
        ybuffer = backshift(ybuffer, m_y)        
    end
    return J
end

function EFE_balance(agent::NARXEFEAgent, goal, control)
    "Analyse terms in Expected Free Energy objective"

    y_ = agent.ybuffer
    u_ = agent.ubuffer
    
    # Track EFE terms
    dJ1 = ForwardDiff.derivative(a -> mutualinfo(agent, y_, u_, a), control)
    dJ2 = ForwardDiff.derivative(a -> crossentropy(agent, y_, u_, goal, a), control)
    dJ3 = 2*agent.η*control
        
    return dJ1,dJ2,dJ3
end

function minimizeEFE(agent::NARXEFEAgent, goals; u_0=nothing, time_limit=10.0, verbose=false, control_lims::Tuple=(-Inf,Inf))
    "Minimize EFE objective and return policy."

    if isnothing(u_0); u_0 = zeros(agent.thorizon); end
    opts = Optim.Options(time_limit=time_limit, 
                         show_trace=verbose, 
                         allow_f_increases=false, 
                         f_tol=1e-8,
                         g_tol=1e-8, 
                         show_every=10,
                         iterations=3_000)

    # Objective function
    J(u) = EFE(agent, goals, u)

    # Constrained minimization procedure
    results = optimize(J, control_lims..., u_0, Fminbox(LBFGS()), opts, autodiff=:forward)

    return Optim.minimizer(results)
end

function backshift(x::AbstractVector, a::Number)
    "Shift elements down and add element"

    N = size(x,1)

    # Shift operator
    S = Tridiagonal(ones(N-1), zeros(N), zeros(N-1))

    # Basis vector
    e = [1.0; zeros(N-1)]

    return S*x + e*a
end

function update_goals!(x::AbstractVector, g::Distribution{Univariate, Continuous})
    "Move goals forward and add a final goal"
    circshift!(x,-1)
    x[end] = g
end

end
