abstract type AbstractObjective end

"$(TYPEDEF) Objective: stores stage cost(s) and terminal cost functions"
struct Objective <: AbstractObjective
    cost::CostTrajectory
end

function Objective(cost::CostFunction,N::Int)
    Objective([cost for k = 1:N])
end

"Input requires separate stage and terminal costs (and trajectory length)"
function Objective(cost::CostFunction,cost_terminal::CostFunction,N::Int)
    Objective([k < N ? cost : cost_terminal for k = 1:N])
end

"Input requires separate stage trajectory and terminal cost"
function Objective(cost::CostTrajectory,cost_terminal::CostFunction)
    Objective([cost...,cost_terminal])
end

import Base.getindex

getindex(obj::Objective,i::Int) = obj.cost[i]

"Calculate unconstrained cost for X and U trajectories"
function cost(obj::Objective, X::AbstractVectorTrajectory{T}, U::AbstractVectorTrajectory{T})::T where T 
    N = length(X)
    J = 0.0
    for k = 1:N-1
        J += stage_cost(obj[k],X[k],U[k])
    end
    J /= (N-1.0)
    J += stage_cost(obj[N],X[N])
    return J
end

function cost_expansion!(Q::ExpansionTrajectory{T}, obj::Objective,
        X::AbstractVectorTrajectory{T}, U::AbstractVectorTrajectory{T}) where T
    cost_expansion!(Q,obj.cost,X,U)
end

function cost_expansion!(Q::ExpansionTrajectory{T}, c::CostTrajectory,
        X::AbstractVectorTrajectory{T}, U::AbstractVectorTrajectory{T}) where T
    N = length(X)
    cost_expansion!(Q[N],c[N],X[N])
    for k = 1:N-1
        cost_expansion!(Q[k],c[k],X[k],U[k])
    end
end

function cost_expansion!(S::Expansion{T},obj::Objective,x::AbstractVector{T}) where T
    cost_expansion!(S,obj.cost[end],x)
    return nothing
end
