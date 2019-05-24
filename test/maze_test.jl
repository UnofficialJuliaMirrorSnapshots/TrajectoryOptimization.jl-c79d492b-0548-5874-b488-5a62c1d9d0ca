# model
T = Float64
integration = :rk4
model = Dynamics.quadrotor_model
n = model.n; m = model.m

q0 = [1.;0.;0.;0.] # unit quaternion

x0 = zeros(T,n)
x0[1:3] = [0.; 0.; 10.]
x0[4:7] = q0

xf = zero(x0)
xf[1:3] = [0.;60.; 10.]
xf[4:7] = q0;

Q = (1.0e-4)*Diagonal(I,n)
R = (1.0e-3)*Diagonal(I,m)
Qf = 1000.0*Diagonal(I,n)
_cost = LQRCost(Q, R, Qf, xf);

r_quad = 2.
r_cylinder = 2.
cylinders = []
zh = 3
l1 = 5
l2 = 4
l3 = 5
l4 = 10

for i = range(-25,stop=-10,length=l1)
    push!(cylinders,(i, 10,r_cylinder))
end

for i = range(10,stop=25,length=l1)
    push!(cylinders,(i, 10, r_cylinder))
end

for i = range(-7.5,stop=7.5,length=l3)
    push!(cylinders,(i, 30, r_cylinder))
end

for i = range(-25,stop=-10,length=l1)
    push!(cylinders,(i, 50, r_cylinder))
end

for i = range(10,stop=25,length=l1)
    push!(cylinders,(i, 50, r_cylinder))
end

for i = range(10+2*r_cylinder,stop=50-2*r_cylinder,length=l4)
    push!(cylinders,(-25, i, r_cylinder))
end

for i = range(10+2*r_cylinder,stop=50-2*r_cylinder,length=l4)
    push!(cylinders,(25, i, r_cylinder))
end

n_cylinders = length(cylinders)

function cI_maze(c,x,u)
    for i = 1:n_cylinders
        c[i] = circle_constraint(x,cylinders[i][1],cylinders[i][2],cylinders[i][3]+r_quad)
    end
end

maze = Constraint{Inequality}(cI_maze,n,m,n_cylinders,:maze)

u_min = 0.
u_max = 20.
x_max = Inf*ones(model.n)
x_min = -Inf*ones(model.n)

x_max[1:3] = [25.0; Inf; 20]
x_min[1:3] = [-25.0; -Inf; 0.]
# bnd = BoundConstraint(n,m,u_min=u_min,u_max=u_max,x_min=x_min,x_max=x_max,trim=true)
bnd = BoundConstraint(n,m,x_min=x_min,x_max=x_max,trim=true)

goal = goal_constraint(xf)
con = [bnd,maze,goal]; # constraint set
# con = [bnd,goal]
verbose=true
opts_ilqr = iLQRSolverOptions{T}(verbose=verbose,iterations=300,live_plotting=:off)

opts_al = AugmentedLagrangianSolverOptions{T}(verbose=verbose,opts_uncon=opts_ilqr,
    iterations=40,cost_tolerance=1.0e-6,cost_tolerance_intermediate=1.0e-6,constraint_tolerance=1.0e-4,penalty_scaling=10.,penalty_initial=1.)

opts_altro = ALTROSolverOptions{T}(verbose=verbose,resolve_feasible_problem=false,opts_al=opts_al,R_inf=0.001);

N = 101 # number of knot points
tf = 5.0
dt = tf/(N-1) # total time

U = [0.5*9.81/4.0*ones(m) for k = 1:N-1] # initial hovering control trajectory
obj = Objective(_cost,N) # objective with same stagewise costs

con_set = ProblemConstraints(con,N) # constraint trajectory

prob = Problem(model,obj, constraints=con_set, x0=x0, integration=:rk4, N=N, dt=dt)
initial_controls!(prob,U); # initialize problem with controls

X_guess = zeros(n,7)
X_guess[:,1] = x0
X_guess[:,7] = xf
X_guess[1:3,2:6] .= [0 -12.5 -20 -12.5 0 ;15 20 30 40 45 ;10 10 10 10 10]

X_guess[4:7,:] .= q0
X0 = TrajectoryOptimization.interp_rows(N,tf,X_guess);

copyto!(prob.X,X0)

solve!(prob,opts_altro)
@test norm(prob.X[N] - xf,Inf) < opts_al.constraint_tolerance
@test max_violation(prob) < opts_al.constraint_tolerance
