import TrajectoryOptimization: Model, LQRCost, Problem, Objective, rollout!, iLQRSolverOptions,
    AbstractSolver, jacobian!, _backwardpass!, _backwardpass_sqrt!, AugmentedLagrangianSolverOptions, ALTROSolverOptions,
    goal_constraint, update_constraints!, update_active_set!, jacobian!, update_problem,
    line_trajectory, total_time

T = Float64

# model
model = TrajectoryOptimization.Dynamics.pendulum_model
n = model.n; m = model.m
model_d = rk4(model)

# cost
Q = Array(1e-3*Diagonal(I,n))
R = Array(1e-3*Diagonal(I,m))
Qf = Array(Diagonal(I,n)*0.0)
x0 = zeros(n)
xf = [pi;0.0]

# options
verbose=false
opts_ilqr = iLQRSolverOptions{T}(verbose=false,live_plotting=:off)
opts_al = AugmentedLagrangianSolverOptions{T}(verbose=false,opts_uncon=opts_ilqr,iterations=50,penalty_scaling=2.0)
opts_altro = ALTROSolverOptions{T}(verbose=false,opts_al=opts_al,R_minimum_time=15.0,dt_max=0.15,dt_min=1.0e-3)

# constraints
u_bnd = 5.
bnd = BoundConstraint(n,m,u_min=-u_bnd,u_max=u_bnd,trim=true)
goal_con = goal_constraint(xf)
con = [bnd, goal_con]

# problem
N = 31
U = [ones(m) for k = 1:N-1]
obj = LQRObjective(Q,R,Qf,xf,N)

dt = 0.15
prob = Problem(model_d,obj,U,constraints=ProblemConstraints(con,N),dt=dt,x0=x0)
solve!(prob,opts_altro)
tt = total_time(prob)

PC_mt = TrajectoryOptimization.mintime_constraints(prob)
@test length(PC_mt[1]) == 2
@test length(PC_mt[2]) == 3
@test length(PC_mt[N]) == 2

C = prob.constraints[1]
C2 = TrajectoryOptimization.update_constraint_set_jacobians(C, n, n+1, m)
@test length(C2) == 2

dt = 0.15/2.0
prob_mt = Problem(model_d,obj,prob.U,constraints=ProblemConstraints(con,N),dt=dt,x0=x0,tf=:min)
solve!(prob_mt,opts_altro)
tt_mt = total_time(prob_mt)

n̄ = n+1
idx = [(1:n)...,((1:m) .+ n̄)...]
[collect(1:n);collect(1:m) .+ n̄]

@test tt_mt < 0.5*tt
@test tt_mt < 1.0

@test norm(prob_mt.X[end] - xf,Inf) < 1e-3
@test max_violation(prob_mt) < opts_al.constraint_tolerance

## Box parallel park
model = TrajectoryOptimization.Dynamics.car_model
n = model.n; m = model.m
model_d = discretize_model(model,:rk4)


# cost
x0 = [0.0;0.0;0.]
xf = [0.0;1.0;0.]
tf =  3.
Qf = 100.0*Diagonal(I,n)
Q = (1e-2)*Diagonal(I,n)
R = (1e-2)*Diagonal(I,m)

# options
verbose=false
opts_ilqr = iLQRSolverOptions{T}(verbose=false,live_plotting=:off)
opts_al = AugmentedLagrangianSolverOptions{T}(verbose=false,opts_uncon=opts_ilqr,
    iterations=30,penalty_scaling=10.0)
opts_altro = ALTROSolverOptions{T}(verbose=false,opts_al=opts_al,R_minimum_time=10.0,
    dt_max=0.2,dt_min=1.0e-3)

# constraints
u_bnd = 2.
x_min = [-0.25; -0.001; -Inf]
x_max = [0.25; 1.001; Inf]
bnd = BoundConstraint(n,m,x_min=x_min,x_max=x_max,u_min=-u_bnd,u_max=u_bnd,trim=true)

goal_con = goal_constraint(xf)
con = [bnd, goal_con]

# problem
N = 51
U = [ones(m) for k = 1:N-1]
obj = LQRObjective(Q,R,Qf,xf,N)

dt = 0.06
prob = Problem(model_d,obj,U,constraints=ProblemConstraints(con,N),dt=dt,x0=x0)
solve!(prob,opts_altro)
tt = total_time(prob)

prob_mt = Problem(model_d,obj,prob.U,constraints=ProblemConstraints(con,N),dt=dt,x0=x0,tf=:min)
solve!(prob_mt,opts_altro)
tt_mt = total_time(prob_mt)

@test tt_mt < 0.75*tt
@test tt_mt < 2.1

@test norm(prob_mt.X[end] - xf,Inf) < 1e-3
@test max_violation(prob_mt) < opts_al.constraint_tolerance
