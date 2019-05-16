import TrajectoryOptimization: DIRCOLSolverOptions, DIRCOLSolver, Primals, gen_ipopt_functions,
    update_problem, create_partition
import TrajectoryOptimization: update_constraints!
import TrajectoryOptimization: traj_points!, dynamics!, calculate_jacobians!, cost_gradient!, constraint_jacobian!,
    collocation_constraints!, collocation_constraint_jacobian!, collocation_constraint_jacobian_sparsity!, constraint_jacobian_sparsity!,
    get_rc

using Test
using ForwardDiff
using LinearAlgebra

# Set up problem
prob = copy(Dynamics.quadrotor_obstacles)
model = Dynamics.quadrotor_model
n,m,N = size(prob)
bnd = BoundConstraint(n, m, u_min=0, u_max=10)
add_constraints!(prob, bnd)

# initial state
x0 = zeros(n)
x0[1:3] = [0.; 0.; 0.]
q0 = [1.;0.;0.;0.]
x0[4:7] = q0

# -final state
xf = copy(x0)
xf[1:3] = [0.;40.;0.] # xyz position
xf[4:7] = q0



## Box parallel park
T = Float64
model = TrajectoryOptimization.Dynamics.car_model
n = model.n; m = model.m
model_d = Model{Discrete}(model,rk4)


# cost
x0 = [0.0;0.0;0.]
xf = [0.0;1.0;0.]
tf =  3.
Qf = 100.0*Diagonal(I,n)
Q = (1e-2)*Diagonal(I,n)
R = (1e-2)*Diagonal(I,m)
lqr_cost = LQRCost(Q,R,Qf,xf)

# options
verbose=false
opts_ilqr = iLQRSolverOptions{T}(verbose=false,live_plotting=:off)
opts_al = AugmentedLagrangianSolverOptions{T}(verbose=false,opts_uncon=opts_ilqr,
    iterations=30,penalty_scaling=10.0)
opts_altro = ALTROSolverOptions{T}(verbose=false,opts_al=opts_al,R_minimum_time=15.0,
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
dt = 0.06
prob = Problem(model_d,Objective(lqr_cost,N),U,constraints=ProblemConstraints(con,N),dt=dt,x0=x0)
prob = Problem(model_d,Objective(lqr_cost,N),U,constraints=ProblemConstraints(N),dt=dt,x0=x0)
rollout!(prob)
prob = update_problem(prob, model=model)


# Create DIRCOL Solver
opts = DIRCOLSolverOptions{Float64}()
prob = update_problem(prob, model=model)
pcon = prob.constraints
dircol = DIRCOLSolver(prob, opts)

N = prob.N
length(dircol.Z.U) == N
part_z = create_partition(n,m,N,N)
NN = N*(n+m)
Z = rand(NN)
copyto!(dircol.Z.Z, Z)

# Convert Z to X,U
Z0 = Primals(Z,n,m)
Z0 = Primals(Z,part_z)
X = Z0.X
U = Z0.U
@test size(Z0) == (n,m,N)
@test length(Z0) == NN

Primals(Z,n,m).X[1][1] = 10
@test X[1][1] == 10
@test Z[1] == 10

Z1 = copy(Z)
Z1[1] = 100
Z1 = Primals(Z1,X,U)
@test Z1.Z[1] == 100
@test Z1.X[1][1] == 100
@test X[1][1] == 100


# Convert fom X,U to Z
X = [rand(n) for k = 1:N]
U = [rand(n) for k = 1:N]
Z2 = Primals(X,U)
@test Z2.equal == true
@test Primals(prob, true).equal == true
Z_rollout = Primals(prob, true)


# Test methods

# Cost
Z = dircol.Z
@test Z.X isa TrajectoryOptimization.AbstractVectorTrajectory
@test typeof(Z.X) <: Vector{S} where S <: AbstractVector
initial_controls!(prob, Z.U)
initial_state!(prob, Z.X)
@test cost(prob, dircol) == cost(prob)

# Collocation constraints
p_colloc = n*(N-1)
p_custom = sum(num_constraints(prob))
g_colloc = zeros(p_colloc)
g = zeros(p_colloc + p_custom)
dynamics!(prob, dircol, Z_rollout)
traj_points!(prob, dircol, Z_rollout)
collocation_constraints!(g_colloc, prob, dircol, Z_rollout)
@test norm(g_colloc,Inf) < 1e-15

# Normal Constraints
dynamics!(prob, dircol, Z)
traj_points!(prob, dircol, Z)
g_custom = view(g, p_colloc.+(1:p_custom))
prob.constraints[N]
update_constraints!(g, prob, dircol)
update_constraints!(dircol.C, prob.constraints, Z.X, Z.U)
p = num_constraints(prob)
@test to_dvecs(g_custom, p) == dircol.C

# Cost gradient
grad_f = zeros(NN)
cost_gradient!(grad_f, prob, dircol)

function eval_f(Z)
    Z = Primals(Z, part_z)
    cost(prob.obj, Z.X, Z.U)
end
eval_f(Z.Z)
@test ForwardDiff.gradient(eval_f, Z.Z) == grad_f

# Collocation Constraint jacobian
dircol = DIRCOLSolver(prob, opts, Z)
dynamics!(prob, dircol, Z)
traj_points!(prob, dircol, Z)
calculate_jacobians!(prob, dircol, Z)

jac = zeros(p_colloc, NN)
collocation_constraint_jacobian!(jac, prob, dircol)

function jac_colloc(Z)
    dynamics!(prob, dircol)
    traj_points!(prob, dircol)
    calculate_jacobians!(prob, dircol, Z)

    jac = zeros(p_colloc, NN)
    collocation_constraints!(g_colloc, prob, dircol, Z)
    collocation_constraint_jacobian!(jac, prob, dircol)
    return jac
end
jac_colloc(Z)

function c_colloc(Z)
    g_colloc = zeros(eltype(Z), p_colloc)
    Z = Primals(Z, part_z)
    solver = DIRCOLSolver(prob, DIRCOLSolverOptions{eltype(Z.Z)}(), Z)
    dynamics!(prob, solver, Z)
    traj_points!(prob, solver, Z)
    collocation_constraints!(g_colloc, prob, solver, Z)
    return g_colloc
end
c_colloc(Z.Z)

@test ForwardDiff.jacobian(c_colloc, Z.Z) ≈ jac_colloc(Z)

nG = p_colloc*2(n+m)
jac = spzeros(p_colloc, NN)
collocation_constraint_jacobian_sparsity!(jac, prob)
@test nG == nnz(jac)
row, col, inds = findnz(jac)
v = sortperm(inds)
r,c = row[v],col[v]
jac_vec = zeros(nG)
collocation_constraint_jacobian!(jac_vec, prob, dircol)
jac2 = sparse(r,c,jac_vec)
@test jac == jac

# General constraint jacobian
jac = zeros(p_colloc+p_custom, NN)
constraint_jacobian_sparsity!(jac, prob)
jac_co, jac_cu = partition_constraint_jacobian(jac, prob)
calculate_jacobians!(prob, dircol, Z)
constraint_jacobian!(jac, prob, dircol, Z)

function c_all(Z)
    g = zeros(eltype(Z), p_colloc+p_custom)
    Z = Primals(Z, part_z)
    solver = DIRCOLSolver(prob, DIRCOLSolverOptions{eltype(Z.Z)}(), Z)
    dynamics!(prob, solver, Z)
    traj_points!(prob, solver, Z)
    update_constraints!(g, prob, solver, Z)
    return g
end
c_all(Z.Z)
@test ForwardDiff.jacobian(c_all, Z.Z) ≈ jac

p = num_constraints(prob)
nG = p_colloc*2(n+m) + sum(p[1:N-1])*(n+m) + p[N]*n
jac_struct = spzeros(p_colloc+p_custom, NN)
constraint_jacobian_sparsity!(jac_struct, prob)
r,c = get_rc(jac_struct)
jac_vec = zeros(nG)
constraint_jacobian!(jac_vec, prob, dircol, dircol.Z)
jac2 = sparse(r,c,jac_vec)
@test jac2 == jac


# Test Ipopt functions
eval_f2, eval_g, eval_grad_f, eval_jac_g = gen_ipopt_functions(prob, dircol)

g2 = zero(g)
grad_f2 = zero(grad_f)
jac2 = zero(jac_vec)
row, col = zero(jac_vec), zero(jac_vec)
@test eval_f2(Z.Z) == eval_f(Z.Z)
eval_g(Z.Z, g2)
@test g ≈ g2
eval_grad_f(Z.Z, grad_f2)
@test grad_f ≈ grad_f2

eval_jac_g(Z.Z, :Structure, row, col, jac2)
eval_jac_g(Z.Z, :Values, r, c, jac2)
@test sparse(row,col,jac2) == jac

prob0 = copy(prob)
remove_bounds!(prob0.constraints[2])
bnds = remove_bounds!(prob0)
dircol0 = DIRCOLSolver(prob0, opts)
z_U,z_L,g_U,g_L = get_bounds(prob0, dircol0, bnds)
vcat(g_U...)
vcat(g_L...)
dircol.C[1].parts
prob0.constraints
sum(num_constraints(prob))

using Ipopt
prob
dircol
problem = solve!(prob, dircol)

solveProblem(problem)


solver = dircol

prob0 = copy(prob)
bnds = remove_bounds!(prob0)
solver0 = DIRCOLSolver(prob0, solver.opts)
eval_f2, eval_g, eval_grad_f, eval_jac_g = gen_ipopt_functions(prob0, solver0)

Z0 = Primals(prob, true)

NN = N*(n+m)
p = num_constraints(prob0)
p_colloc = num_colloc(prob0)
p_custom = sum(p)
P = p_colloc + p_custom
nG = p_colloc*2(n+m) + sum(p[1:N-1])*(n+m) + p[N]*n
nH = 0

z_U, z_L, g_U, g_L = get_bounds(prob0, dircol0, bnds)
z_U = z_U.Z
z_L = z_L.Z
convertInf!(z_U, 1e10)
convertInf!(z_L, 1e10)
g_U = vcat(zeros(p_colloc), g_U...)
g_L = vcat(zeros(p_colloc), g_L...)

Z = Z0.Z
plot(Z0.X)


g = zeros(P)
grad_f = zeros(NN)
r,c,v = zeros(nG), zeros(nG), zeros(nG)
eval_f2(Z)
eval_g(Z,g)
eval_grad_f(Z, grad_f)
eval_jac_g(Z, :Structure, r, c, v)
eval_jac_g(Z, :Values, r, c, v)

problem = Ipopt.createProblem(NN, z_L, z_U, P, g_L, g_U, nG, nH,
    eval_f, eval_g, eval_grad_f, eval_jac_g)
problem.x = Z0.Z

solveProblem(problem)

ilqr = iLQRSolverOptions()
U0 = ones(m,N-1)
initial_controls!(prob, U0)
prob_d = rk4(prob)
prob_sol = solve(prob_d, ilqr)
initial_controls!(prob, prob_sol.U)
initial_state!(prob, prob_sol.X)

plot(prob_sol.X)

prob
num_constraints(prob)
problem = solve!(prob, DIRCOLSolver(prob, opts))


solveProblem(problem)
Zsol = Primals(problem.x,Z0)

plot(Zsol.X)



# Re-create the problem with rolled out trajectory
U0 = ones(m,N-1)
prob = Problem(model_d,Objective(lqr_cost,N),U0,constraints=ProblemConstraints(N),dt=dt,x0=x0)
rollout!(prob)
prob = update_problem(prob, model=model)

# Extract out X,U
n,m,N = size(prob)
NN = (n+m)N
dt = prob.dt
Z = Primals(prob, true).Z
part_z = create_partition(n,m,N,N)
X,U = unpackZ(Z, part_z)

# Get the cost
cost(prob.obj, X, U)

# Check mipoints
fVal = dynamics(prob, X, U)
xs = [x[1] for x in X]
ys = [x[2] for x in X]
scatter(xs,ys)
Xm = traj_points(prob, X, U, fVal)
xm = [x[1] for x in Xm]
ym = [x[2] for x in Xm]
scatter!(xm,ym)

# Check collocation constraints
p_colloc = num_colloc(prob)
p_colloc == (N-1)*n
g = zeros(p_colloc)
collocation_constraints(g, prob, X, U)
x1,u1 = X[1], U[1];
x2,u2 = X[2], U[2];
f1,f2,fm = zero(x1), zero(x2), zero(x1);
evaluate!(f1, model, x1, u1)
evaluate!(f2, model, x2, u2)
f1 == fVal[1]
f2 == fVal[2]
xm = 0.5*(x1+x2) + dt/8*(f1-f2)
xm == Xm[1]
um = (u1+u2)/2
evaluate!(fm, model, xm, um)

err1 = x2-x1 - dt/6*(f1 + 4fm + f2)
@test norm(err1) <= 1e-15
@test norm(g) < 1e-15

# Cost gradient
function eval_cost(Z)
    X,U = unpackZ(Z,part_z)
    cost(prob.obj, X, U)
end
grad_f = zeros(NN)
cost_gradient!(grad_f, prob, X, U)
@test ForwardDiff.gradient(eval_cost, Z) ≈ grad_f

# Collocation jacobian
function colloc(Z)
    X,U = unpackZ(Z,part_z)
    g = zeros(eltype(Z),p_colloc)
    collocation_constraints(g, prob, X, U)
    return g
end
jac_co = zeros(p_colloc, NN)
collocation_constraint_jacobian!(jac_co, prob, X, U)
@test ForwardDiff.jacobian(colloc, Z) ≈ jac_co

jac_struct = spzeros(p_colloc, NN)
collocation_constraint_jacobian_sparsity!(jac_struct, prob)
get_rc(jac_struct)

eval_f2, eval_g, eval_grad_f, eval_jac_g = gen_ipopt_functions2(prob, solver)
r,c,v = zeros(nG), zeros(nG), zeros(nG)
eval_jac_g(jac_co, :Structure, r, c, v)

P = p_colloc
nG = p_colloc*2(n+m)
nH = 0
z_L = ones(NN)*-1e5
z_U = ones(NN)*1e5
g_L = zeros(P)
g_U = zeros(P)
problem = Ipopt.createProblem(NN, z_L, z_U, P, g_L, g_U, nG, nH,
    eval_f2, eval_g, eval_grad_f, eval_jac_g)
Zinit = Primals([zeros(n) for k = 1:N], [ones(m) for k = 1:N])
opt_file = joinpath(root_dir(),"ipopt.opt")
addOption(problem,"option_file_name",opt_file)
problem.x = Zinit.Z

solveProblem(problem)
Zsol = Primals(problem.x, Z0)
plot(Zsol.X)
