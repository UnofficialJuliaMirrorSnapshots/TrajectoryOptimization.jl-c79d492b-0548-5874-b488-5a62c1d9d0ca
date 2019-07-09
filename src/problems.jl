"""
    Problems
        Collection of trajectory optimization problems
"""
module Problems

using TrajectoryOptimization
using RigidBodyDynamics
using LinearAlgebra
using ForwardDiff
using Plots

include("../problems/doubleintegrator.jl")
include("../problems/pendulum.jl")
include("../problems/parallel_park.jl")
include("../problems/cartpole.jl")
include("../problems/doublependulum.jl")
include("../problems/acrobot.jl")
include("../problems/car_escape.jl")
include("../problems/quadrotor_maze.jl")
# include("../problems/kuka.jl")
# include("../problems/kuka_obstacles.jl")

export
    doubleintegrator_problem,
    pendulum_problem,
    box_parallel_park_problem,
    box_parallel_park_min_time_problem,
    cartpole_problem,
    doublependulum_problem,
    acrobot_problem,
    car_escape_problem,
    quadrotor_maze_problem

export
    plot_escape

end
