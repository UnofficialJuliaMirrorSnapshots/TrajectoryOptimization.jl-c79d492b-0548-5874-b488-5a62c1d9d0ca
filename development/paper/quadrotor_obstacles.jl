using Plots
using MeshCat
using GeometryTypes
using CoordinateTransformations
using FileIO
using MeshIO
using Random
IMAGE_DIR = joinpath(TrajectoryOptimization.root_dir(),"development","paper","images")

Random.seed!(123)

# Solver options
N = 101 # 201
integration = :rk4
opts = SolverOptions()
opts.verbose = false
opts.square_root = true
opts.cost_tolerance = 1e-5
opts.cost_tolerance_intermediate = 1e-5
opts.constraint_tolerance = 1e-4
opts.outer_loop_update_type = :feedback

dircol_options = Dict("tol"=>opts.cost_tolerance,"constr_viol_tol"=>opts.constraint_tolerance)

# Obstacle Avoidance
model,obj_uncon = TrajectoryOptimization.Dynamics.quadrotor
r_quad = 3.0
n = model.n
m = model.m
obj_con = TrajectoryOptimization.Dynamics.quadrotor_3obs[2]
spheres = TrajectoryOptimization.Dynamics.quadrotor_3obs[3]
n_spheres = length(spheres)

solver_uncon = Solver(model,obj_uncon,integration=integration,N=N,opts=opts)
solver_con = Solver(model,obj_con,integration=integration,N=N,opts=opts)

U_hover = 0.5*9.81/4.0*ones(solver_uncon.model.m, solver_uncon.N-1)
X_hover = rollout(solver_uncon,U_hover)
@time results_uncon, stats_uncon = solve(solver_uncon,U_hover)
@time results_uncon_dircol, stats_uncon_dircol = TrajectoryOptimization.solve_dircol(solver_uncon, X_hover, U_hover, options=dircol_options)

@time results_con, stats_con = solve(solver_con,U_hover)
@time results_dircol, stats_dircol = TrajectoryOptimization.solve_dircol(solver_con, X_hover, U_hover, options=dircol_options)

# Trajectory plots
t_array = range(0,stop=solver_con.obj.tf,length=solver_con.N)
plot(t_array[1:end-1],to_array(results_con.U)',title="Quadrotor Obstacle Avoidance",xlabel="time",ylabel="control",labels="")
savefig(joinpath(IMAGE_DIR,"quadrotor_obstacles_control_traj.eps"))
plot(t_array,to_array(results_con.X)[1:3,:]',title="Quadrotor Obstacle Avoidance",xlabel="time",ylabel="position",labels=["x";"y";"z"],legend=:topleft)
savefig(joinpath(IMAGE_DIR,"quadrotor_obstacles_pos_traj.eps"))

plot(t_array[1:end-1],Array(results_uncon_dircol.U)[:,1:end-1]',title="Quadrotor Obstacle Avoidance",xlabel="time",ylabel="control",labels="dircol")
plot(t_array,Array(results_uncon_dircol.X)[1:3,:]',title="Quadrotor Obstacle Avoidance",xlabel="time",ylabel="control",labels="dircol")

t_array = range(0,stop=solver_con.obj.tf,length=solver_con.N)
plot(t_array[1:end-1],Array(results_dircol.U)[:,1:end-1]',title="Quadrotor Obstacle Avoidance",xlabel="time",ylabel="control",labels="")
savefig(joinpath(IMAGE_DIR,"quadrotor_obstacles_control_traj_dircol.eps"))
plot(t_array,Array(results_dircol.X)[1:3,:]',title="Quadrotor Obstacle Avoidance",xlabel="time",ylabel="position",labels=["x";"y";"z"],legend=:topleft)
savefig(joinpath(IMAGE_DIR,"quadrotor_obstacles_pos_traj_dircol.eps"))

@assert max_violation(results_con) <= opts.constraint_tolerance

# Constraint convergence plot
plot(stats_con["c_max"],yscale=:log10,title="Quadrotor Obstacle Avoidance",xlabel="iteration",ylabel="max constraint violation",label="ALTRO")
savefig(joinpath(IMAGE_DIR,"quadrotor_obstacles_constraint_convergence.eps"))
plot(stats_dircol["c_max"],yscale=:log10,title="Quadrotor Obstacle Avoidance",xlabel="iteration",ylabel="log(max constraint violation)",label="DIRCOL")
savefig(joinpath(IMAGE_DIR,"quadrotor_obstacles_constraint_convergence_dircol.eps"))

@show stats_con["iterations"]
@show stats_con["outer loop iterations"]
@show stats_con["c_max"][end]
@show stats_con["cost"][end]

#################
# Visualization #
#################

vis = Visualizer()
open(vis)

# Import quadrotor obj file
traj_folder = joinpath(dirname(pathof(TrajectoryOptimization)),"..")
urdf_folder = joinpath(traj_folder, "dynamics","urdf")
obj = joinpath(urdf_folder, "quadrotor_base.obj")

# color options
green_ = MeshPhongMaterial(color=RGBA(0, 1, 0, 1.0))
green_transparent = MeshPhongMaterial(color=RGBA(0, 1, 0, 0.1))
red_ = MeshPhongMaterial(color=RGBA(1, 0, 0, 1.0))
blue_ = MeshPhongMaterial(color=RGBA(0, 0, 1, 1.0))
blue_transparent = MeshPhongMaterial(color=RGBA(0, 0, 1, 0.1))

orange_ = MeshPhongMaterial(color=RGBA(233/255, 164/255, 16/255, 1.0))
orange_transparent = MeshPhongMaterial(color=RGBA(233/255, 164/255, 16/255, 0.1))
black_ = MeshPhongMaterial(color=RGBA(0, 0, 0, 1.0))
black_transparent = MeshPhongMaterial(color=RGBA(0, 0, 0, 0.1))

# geometries
robot_obj = FileIO.load(obj)
sphere_small = HyperSphere(Point3f0(0), convert(Float32,0.1*r_quad)) # trajectory points
sphere_medium = HyperSphere(Point3f0(0), convert(Float32,r_quad))

obstacles = vis["obs"]
traj = vis["traj"]
traj_uncon = vis["traj_uncon"]
target = vis["target"]
robot = vis["robot"]
robot_uncon = vis["robot_uncon"]

# Set camera location
settransform!(vis["/Cameras/default"], compose(Translation(25., 15., 20.),LinearMap(RotY(-pi/12))))

# Create and place obstacles
for i = 1:n_spheres
    setobject!(vis["obs"]["s$i"],HyperSphere(Point3f0(0), convert(Float32,spheres[i][4])),red_)
    settransform!(vis["obs"]["s$i"], Translation(spheres[i][1], spheres[i][2], spheres[i][3]))
end

# Create and place trajectory
for i = 1:N
    setobject!(vis["traj_uncon"]["t$i"],sphere_small,orange_)
    settransform!(vis["traj_uncon"]["t$i"], Translation(results_uncon.X[i][1], results_uncon.X[i][2], results_uncon.X[i][3]))
end
for i = 1:N
    setobject!(vis["traj"]["t$i"],sphere_small,blue_)
    settransform!(vis["traj"]["t$i"], Translation(results_con.X[i][1], results_con.X[i][2], results_con.X[i][3]))
end

# Create and place initial position
# setobject!(vis["robot_uncon"]["ball"],sphere_medium,orange_transparent)
# setobject!(vis["robot_uncon"]["quad"],robot_obj,black_)

# setobject!(vis["robot"]["ball"],sphere_medium,blue_transparent)
setobject!(vis["robot"]["quad"],robot_obj,black_)

# Animate quadrotor
for i = 1:N
    settransform!(vis["robot_uncon"], compose(Translation(results_uncon.X[i][1:3]...),LinearMap(Quat(results_uncon.X[i][4:7]...))))
    sleep(solver_uncon.dt)
end

for i = 1:N
    settransform!(vis["robot"], compose(Translation(results_con.X[i][1:3]...),LinearMap(Quat(results_con.X[i][4:7]...))))
    sleep(solver_con.dt)
end

# Ghose quadrotor scene
traj_idx = [1;15;25;35;50;N]
n_robots = length(traj_idx)
for i = 1:n_robots
    robot = vis["robot_$i"]
    setobject!(vis["robot_$i"]["quad"],robot_obj,black_)
    settransform!(vis["robot_$i"], compose(Translation(results_con.X[traj_idx[i]][1:3]...),LinearMap(Quat(results_con.X[traj_idx[i]][4:7]...))))
end
