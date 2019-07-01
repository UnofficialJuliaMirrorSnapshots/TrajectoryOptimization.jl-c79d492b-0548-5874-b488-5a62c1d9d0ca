cost(prob::Problem, V::PrimalDual) = cost(prob.obj, V.X, V.U)

############################
#       CONSTRAINTS        #
############################
function dynamics_constraints!(prob::Problem, solver::DirectSolver, V=solver.V)
    N = prob.N
    X,U = V.X, V.U
    solver.fVal[1] .= V.X[1] - prob.x0
    for k = 1:N-1
         evaluate!(solver.fVal[k+1], prob.model, X[k], U[k], prob.dt)
         solver.fVal[k+1] .-= X[k+1]
     end
 end


function dynamics_jacobian!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V)
    n,m,N = size(prob)
    X,U = V.X, V.U
    solver.∇F[1].xx .= Diagonal(I,n)
    solver.Y[1:n,1:n] .= Diagonal(I,n)
    part = (x=1:n, u =n .+ (1:m), x1=n+m .+ (1:n))
    p = num_constraints(prob)
    off1 = n
    off2 = 0
    for k = 1:N-1
        jacobian!(solver.∇F[k+1], prob.model, X[k], U[k], prob.dt)
        solver.Y[off1 .+ part.x, off2 .+ part.x] .= solver.∇F[k+1].xx
        solver.Y[off1 .+ part.x, off2 .+ part.u] .= solver.∇F[k+1].xu
        solver.Y[off1 .+ part.x, off2 .+ part.x1] .= -Diagonal(I,n)
        off1 += n + p[k]
        off2 += n+m
    end
end

function update_constraints!(prob::Problem, solver::DirectSolver, V=solver.V)
    n,m,N = size(prob)
    for k = 1:N-1
        evaluate!(solver.C[k], prob.constraints[k], V.X[k], V.U[k])
    end
    evaluate!(solver.C[N], prob.constraints[N], V.X[N])
end

function active_set!(prob::Problem, solver::ProjectedNewtonSolver)
    n,m,N = size(prob)
    P = sum(num_constraints(prob)) + n*N
    a0 = copy(solver.a)
    for k = 1:N
        active_set!(solver.active_set[k], solver.C[k], solver.opts.active_set_tolerance)
    end
    if solver.opts.verbose && a0 != solver.a
        println("active set changed")
    end
end

function active_set!(a::AbstractVector{Bool}, c::AbstractArray{T}, tol::T=0.0) where T
    a0 = copy(a)
    equality, inequality = c.parts[:equality], c.parts[:inequality]
    a[equality] .= true
    a[inequality] .= c.inequality .>= -tol
end


######################################
#       CONSTRAINT JACBOBIANS        #
######################################
function constraint_jacobian!(prob::Problem, ∇C::Vector, X, U)
    n,m,N = size(prob)
    for k = 1:N-1
        jacobian!(∇C[k], prob.constraints[k], X[k], U[k])
    end
    jacobian!(∇C[N], prob.constraints[N], X[N])
end
constraint_jacobian!(prob::Problem, solver::DirectSolver, V=solver.V) =
    constraint_jacobian!(prob, solver.∇C, V.X, V.U)
# constraint_jacobian!(prob::Problem, Y::KKTJacobian, V=solver.V) =
#     constraint_jacobian!(prob, Y.∇C, V.X, V.U)

function active_constraints(prob::Problem, solver::ProjectedNewtonSolver)
    n,m,N = size(prob)
    a = solver.a.duals
    # return view(solver.Y, a, :), view(solver.y, a)
    return solver.Y.blocks[a,:], solver.y[a]
end


############################
#      COST EXPANSION      #
############################
cost_expansion!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V) =
    cost_expansion!(solver.Q, prob.obj, V.X, V.U)


function cost_expansion!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V) where T
    n,m,N = size(prob)
    NN = N*n + (N-1)*m
    H = solver.H
    g = solver.g

    part = (x=1:n, u=n .+ (1:m), z=1:n+m)
    part2 = (xx=(part.x, part.x), uu=(part.u, part.u), ux=(part.u, part.x), xu=(part.x, part.u))
    off = 0
    for k = 1:N-1
        # H[off .+ part.x, off .+ part.x] = Q[k].xx
        # H[off .+ part.x, off .+ part.u] = Q[k].ux'
        # H[off .+ part.u, off .+ part.x] = Q[k].ux
        # H[off .+ part.u, off .+ part.u] = Q[k].uu
        hess = PartedMatrix(view(H, off .+ part.z, off .+ part.z), part2)
        grad = PartedVector(view(g, off .+ part.z), part)
        hessian!(hess, prob.obj[k], V.X[k], V.U[k])
        gradient!(grad, prob.obj[k], V.X[k], V.U[k])
        off += n+m
    end
    H ./= (N-1)
    g ./= (N-1)
    hess = PartedMatrix(view(H, off .+ part.x, off .+ part.x), part2)
    grad = PartedVector(view(g, off .+ part.x), part)
    hessian!(hess, prob.obj[N], V.X[N])
    gradient!(grad, prob.obj[N], V.X[N])
end



######################
#     FUNCTIONS      #
######################
function update!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V, active_set=true)
    dynamics_constraints!(prob, solver, V)
    update_constraints!(prob, solver, V)
    dynamics_jacobian!(prob, solver, V)
    constraint_jacobian!(prob, solver, V)
    cost_expansion!(prob, solver, V)
    if active_set
        active_set!(prob, solver)
    end
end

function max_violation(solver::DirectSolver{T}) where T
    c_max = 0.0
    C = solver.C
    N = length(C)
    for k = 1:N
        if length(C[k].equality) > 0
            c_max = max(norm(C[k].equality,Inf), c_max)
        end
        if length(C[k].inequality) > 0
            c_max = max(pos(maximum(C[k].inequality)), c_max)
        end
        c_max = max(norm(solver.fVal[k], Inf), c_max)
    end
    return c_max
end

function calc_violations(solver::ProjectedNewtonSolver{T}) where T
    C = solver.C
    N = length(C)
    v = [zero(c) for c in C]
    v = zeros(N)
    for k = 1:N
        if length(C[k].equality) > 0
            v[k] = norm(C[k].equality,Inf)
        end
        if length(C[k].inequality) > 0
            v[k] = max(pos(maximum(C[k].inequality)), v[k])
        end
    end
    return v
end

function projection!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V, active_set_update=true)
    Z = primals(V)
    eps_feasible = solver.opts.feasibility_tolerance
    count = 0
    # cost_expansion!(prob, solver, V)
    H = Diagonal(solver.H)
    while true
        dynamics_constraints!(prob, solver, V)
        update_constraints!(prob, solver, V)
        dynamics_jacobian!(prob, solver, V)
        constraint_jacobian!(prob, solver, V)
        if active_set_update
            active_set!(prob, solver)
        end
        Y,y = active_constraints(prob, solver)
        HinvY = H\Y'

        viol = norm(y,Inf)
        if solver.opts.verbose
            println("feas: ", viol)
        end
        if viol < eps_feasible || count > 10
            break
        else
            δZ = -HinvY*((Y*HinvY)\y)
            Z .+= δZ
            count += 1
        end
    end
end

function multiplier_projection!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V)
    g = solver.g
    a = solver.a.duals
    Y,y = active_constraints(prob, solver)
    λ = duals(V)[a]

    res0 = g + Y'λ
    δλ = -(Y*Y')\(Y*res0)
    λ_ = λ + δλ
    res = g + Y'*λ_
    @show size(view(duals(V),a))
    @show size(λ_)
    copyto!(view(duals(V),a), λ_)
    res = norm(residual(prob, solver, V))
    return res
end

function solveKKT(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V)
    a = solver.a
    δV = zero(V.V)
    λ = duals(V)[a.duals]
    Y,y = active_constraints(prob, solver)
    H,g = solver.H, solver.g
    Pa = length(y)
    A = [H Y'; Y zeros(Pa,Pa)]
    b = [g + Y'λ; y]
    δV[a] = -A\b
    return δV
end

function solveKKT_Shur(prob::Problem, solver::ProjectedNewtonSolver, Hinv, V=solver.V)
    a = solver.a
    δV = zero(V.V)
    λ = duals(V)[a.duals]
    Y,y = active_constraints(prob, solver)
    g = solver.g

    YHinv = Y*Hinv
    S0 = Symmetric(YHinv*Y')
    L = cholesky(S0)
    δλ = L\(y-YHinv*g)
    δz = -Hinv*(g+Y'δλ)

    δV[solver.parts.primals] .= δz
    δV[solver.parts.duals[solver.a.duals]] .= δλ
    return δV
end

function solveKKT_chol(prob::Problem, solver::ProjectedNewtonSolver, Qinv, Rinv, A, B, C, D, V=solver.V)
    a = solver.a
    δV = zero(V.V)
    λ = duals(V)[a.duals]
    Y,y = active_constraints(prob, solver)
    g = solver.g

    L = chol_newton(prob, solver, Qinv, Rinv, A, B, C, D)
    C = Cholesky(Array(L),'L',0)

    YHinv = Y*Hinv
    # S0 = L*L'
    # δλ = L'\(L\(y-YHinv*g))
    δλ = C\(y-YHinv*g)
    δz = -Hinv*(g+Y'δλ)

    δV[solver.parts.primals] .= δz
    δV[solver.parts.duals[solver.a.duals]] .= δλ
    return δV
end

function solveKKT_chol_seq(prob::Problem, solver::ProjectedNewtonSolver, Qinv, Rinv, A, B, C, D, V=solver.V)
    a = solver.a
    δV = zero(V.V)
    λ = duals(V)[a.duals]
    Y,y = active_constraints(prob, solver)
    g = solver.g

    YHinv = Y*Hinv
    δλ, = solve_cholesky(prob, solver, Qinv, Rinv, A, B, C, D)
    δz = -Hinv*(g+Y'δλ)

    δV[solver.parts.primals] .= δz
    δV[solver.parts.duals[solver.a.duals]] .= Array(δλ)
    return δV
end

function residual(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V)
    a = solver.a
    Y,y = active_constraints(prob, solver)
    λ = duals(V)[a.duals]
    g = solver.g
    res = [g + Y'λ; y]
end


function line_search(prob::Problem, solver::ProjectedNewtonSolver, δV)
    α = 1.0
    s = 0.01
    J0 = cost(prob, solver.V)
    update!(prob, solver)
    res0 = norm(residual(prob, solver))
    count = 0
    solver.opts.verbose ? println("res0: $res0") : nothing
    while count < 10
        V_ = solver.V + α*δV
        # projection!(prob, solver, V_)

        # Calculate residual
        projection!(prob, solver, V_)
        res = multiplier_projection!(prob, solver, V_)
        J = cost(prob, V_)

        # Calculate max violation
        viol = max_violation(solver)

        if solver.opts.verbose
            println("cost: $J \t residual: $res \t feas: $viol")
        end
        if res < (1-α*s)*res0
            solver.opts.verbose ? println("α: $α") : nothing
            return V_
        end
        count += 1
        α /= 2
    end
    return solver.V
end






function newton_step!(prob::Problem, solver::ProjectedNewtonSolver)
    V = solver.V
    verbose = solver.opts.verbose

    # Initial stats
    update!(prob, solver)
    J0 = cost(prob, V)
    res0 = norm(residual(prob, solver))
    viol0 = max_violation(solver)

    # Projection
    verbose ? println("\nProjection:") : nothing
    projection!(prob, solver)
    update!(prob, solver)
    multiplier_projection!(prob, solver)

    # Solve KKT
    J1 = cost(prob, V)
    res1 = norm(residual(prob, solver))
    viol1 = max_violation(solver)
    δV = solveKKT(prob, solver)

    # Line Search
    verbose ? println("\nLine Search") : nothing
    V_ = line_search(prob, solver, δV)
    J_ = cost(prob, V_)
    res_ = norm(residual(prob, solver, V_))
    viol_ = max_violation(solver)

    # Print Stats
    if verbose
        println("\nStats")
        println("cost: $J0 → $J1 → $J_")
        println("res: $res0 → $res1 → $res_")
        println("viol: $viol0 → $viol1 → $viol_")
    end

    return V_
end


function buildShurCompliment(prob::Problem, solver::ProjectedNewtonSolver)
    n,m,N = size(prob)

    Hinv = inv(Diagonal(solver.H))
    Qinv = [begin
                off = (k-1)*(n+m) .+ (1:n);
                Diagonal(Hinv[off,off]);
            end for k = 1:N]
    Rinv = [begin
                off = (k-1)*(n+m) .+ (n+1:n+m);
                Diagonal(Hinv[off,off]);
            end for k = 1:N-1]

    A = [F.xx for F in solver.∇F[2:end]]  # First jacobian is for initial condition
    B = [F.xu for F in solver.∇F[2:end]]
    C = [Array(F.x[a,:]) for (F,a) in zip(solver.∇C, solver.active_set)]
    D = [Array(F.u[a,:]) for (F,a) in zip(solver.∇C, solver.active_set)]

    P = num_active_constraints(solver)
    S = spzeros(P,P)

    _buildShurCompliment!(S, prob, solver, Qinv, Rinv, A, B, C, D)

    L = chol_newton(prob, solver, Qinv, Rinv, A, B, C, D)

    return Symmetric(S), L
end

function _buildShurCompliment!(S, prob::Problem, solver::ProjectedNewtonSolver, Qinv, Rinv, A, B, C, D)
    n,m,N = size(prob)

    p = sum.(solver.active_set)
    pcum = insert!(cumsum(p), 1, 0)

    dinds = 1:n
    cinds = n .+ (1:p[1])
    S[dinds,dinds] = Qinv[1]
    S[dinds,n .+ dinds] = Qinv[1]*A[1]'
    S[dinds,n .+ cinds] = Qinv[1]*C[1]'

    for k = 1:N-1
        off = pcum[k] + k*n
        dinds = off .+ (1:n)
        cinds = off + n .+ (1:p[k])
        S[dinds,dinds] = A[k]*Qinv[k]*A[k]' + B[k]*Rinv[k]*B[k]' + Qinv[k+1]
        S[dinds,cinds] = A[k]*Qinv[k]*C[k]' + B[k]*Rinv[k]*D[k]'
        S[cinds,cinds] = C[k]*Qinv[k]*C[k]' + D[k]*Rinv[k]*D[k]'
        if k < N-1
            S[dinds,dinds .+ (p[k] + n)] = -Qinv[k+1]*A[k+1]'
            S[dinds, (off + p[k] + 2n) .+ (1:p[k+1])] = -Qinv[k+1]*C[k+1]'
        else
            S[dinds, (off + p[k] + n) .+ (1:p[k+1])] = -Qinv[k+1]*C[k+1]'
        end
    end
    off = pcum[N] + N*n
    cinds = off .+ (1:p[N])
    S[cinds,cinds] = C[N]*Qinv[N]*C[N]'

end

function chol_newton(prob, solver, Qinv, Rinv, A, B, C, D)
    n,m,N = size(prob)
    P = num_active_constraints(solver)
    S = LowerTriangular(zeros(P,P))

    # Block indices
    len = ones(Int,2,N-1)*n
    p = sum.(solver.active_set)
    len[2,:] = p[1:end-1]
    len = append!([1,3], vec(len))
    push!(len, p[N])
    lcum = cumsum(len)
    ind = [lcum[k]:lcum[k+1]-1 for k = 1:length(lcum)-1]

    # Initial condition
    G0 = cholesky(Qinv[1]).L
    F1 = A[1]*G0
    G1 = cholesky(Symmetric(B[1]*Rinv[1]*B[1]' + Qinv[2]))
    L1 = C[1]*G0
    M1 = D[1]*Rinv[1]*B[1]'/(G1.U)
    N1 = cholesky(D[1]*Rinv[1]*D[1]' - M1*M1')

    S[ind[1], ind[1]] = G0
    S[ind[2], ind[1]] = F1
    S[ind[2], ind[2]] = G1.L
    S[ind[3], ind[1]] = L1
    S[ind[3], ind[2]] = M1
    S[ind[3], ind[3]] = N1.L


    G_ = G1
    M_ = M1
    N_ = N1
    for k = 2:N-1
        E = -A[k]*Qinv[k]/G_.U
        F = -E*M_'/N_.U
        G = cholesky(Symmetric(A[k]*Qinv[k]*A[k]' + B[k]*Rinv[k]*B[k]' + Qinv[k+1] - E*E' - F*F'))

        K = -C[k]*Qinv[k]/G_.U
        L = -K*M_'/N_.U
        Q = inv(Qinv[k])
        M = (C[k]*Qinv[k]*( Q - G_.U\(I - (M_'/N_.U) * (N_.L\M_) )/G_.L )*Qinv[k]*A[k]' + D[k]*Rinv[k]*B[k]')/G.U
        N = cholesky(C[k]*Qinv[k]*C[k]' + D[k]*Rinv[k]*D[k]' - K*K' - L*L' - M*M')

        i = 4 + (k-2)*2
        j = 2 + (k-2)*2
        S[ind[i],   ind[j]  ] = E
        S[ind[i],   ind[j+1]] = F
        S[ind[i],   ind[j+2]] = G.L
        S[ind[i+1], ind[j]  ] = K
        S[ind[i+1], ind[j+1]] = L
        S[ind[i+1], ind[j+2]] = M
        S[ind[i+1], ind[j+3]] = N.L

        G_,M_,N_ = G,M,N
    end
    N = prob.N

    E = -C[N]*Qinv[N]/G_.U
    F = -E*M_'/N_.U
    G = cholesky(Symmetric(C[N]*Qinv[N]*C[N]' - E*E' - F*F'))

    i = 4 + (N-2)*2
    j = 2 + (N-2)*2
    S[ind[i], ind[j]  ] = E
    S[ind[i], ind[j+1]] = F
    S[ind[i], ind[j+2]] = G.L

    return S
end

function solve_cholesky(prob::Problem, solver::ProjectedNewtonSolver, Hinv, Qinv, Rinv, A, B, C, D)
    n,m,N = size(prob)
    Nb = 2N  # number of blocks
    p_active = sum.(solver.active_set)
    y_part = [sum(solver.a.A[Block(k)]) for k = 2:2N+1]
    Pa = sum(y_part)

    Y,y = active_constraints(prob, solver)
    g = solver.g

    r = PseudoBlockArray(y - Y*Hinv*g, y_part)
    λ_ = BlockArray(zeros(Pa), y_part)
    λ = BlockArray(zeros(Pa), y_part)

    # Init arrays
    E = [zeros(n,n) for p in p_active]
    F = [zeros(p,n) for p in p_active]
    G = [cholesky(Matrix(I,n,n)) for p in p_active]

    K = [zeros(p,n) for p in p_active]
    L = [zeros(n,n) for p in p_active]
    M = [zeros(p,n) for p in p_active]
    H = [cholesky(Matrix(I,n,n)) for p in p_active]

    # Initial condition
    G0 = cholesky(Qinv[1])
    λ_[Block(1)] = G0.L\r[Block(1)]

    F[1] = A[1]*G0.L
    G[1] = cholesky(Symmetric(B[1]*Rinv[1]*B[1]' + Qinv[2]))
    λ_[Block(2)] = G[1].L\(r[Block(2)] - F[1]*λ_[Block(1)])

    L[1] = C[1]*G0.L
    M[1] = D[1]*Rinv[1]*B[1]'/(G[1].U)
    H[1] = cholesky(D[1]*Rinv[1]*D[1]' - M[1]*M[1]')
    λ_[Block(3)] = H[1].L\(r[Block(3)] - M[1]*λ_[Block(2)] - L[1]*λ_[Block(1)])

    G_ = G[1]
    M_ = M[1]
    H_ = H[1]
    i = 4
    for k = 2:N-1
        E[k] = -A[k]*Qinv[k]/G_.U
        F[k] = -E[k]*M_'/H_.U
        G[k] = cholesky(Symmetric(A[k]*Qinv[k]*A[k]' + B[k]*Rinv[k]*B[k]' + Qinv[k+1] - E[k]*E[k]' - F[k]*F[k]'))
        # println("\n Time Step $k")
        # @show i
        # @show size(F)
        # @show size(λ_[Block(i-1)])
        λ_[Block(i)] = G[k].L\(r[Block(i)] - F[k]*λ_[Block(i-1)] - E[k]*λ_[Block(i-2)])
        i += 1

        K[k] = -C[k]*Qinv[k]/G_.U
        L[k] = -K[k]*M_'/H_.U
        Q = inv(Qinv[k])
        M[k] = (C[k]*Qinv[k]*( Q - G_.U\(I - (M_'/H_.U) * (H_.L\M_) )/G_.L )*Qinv[k]*A[k]' + D[k]*Rinv[k]*B[k]')/G[k].U
        H[k] = cholesky(C[k]*Qinv[k]*C[k]' + D[k]*Rinv[k]*D[k]' - K[k]*K[k]' - L[k]*L[k]' - M[k]*M[k]')
        # @show i
        # @show size(r[Block(i)])
        # @show size(L)
        # @show size(λ_[Block(i-2)])
        λ_[Block(i)] = H[k].L\(r[Block(i)] - M[k]*λ_[Block(i-1)] - L[k]*λ_[Block(i-2)] - K[k]*λ_[Block(i-3)])
        i += 1

        G_, M_, H_ = G[k], M[k], H[k]
    end

    # Terminal
    N = prob.N

    E[N] = -C[N]*Qinv[N]/G_.U
    F[N] = -E[N]*M_'/H_.U
    G[N] = cholesky(Symmetric(C[N]*Qinv[N]*C[N]' - E[N]*E[N]' - F[N]*F[N]'))
    λ_[Block(i)] = G[N].L\(r[Block(i)] - F[N]*λ_[Block(i-1)] - E[N]*λ_[Block(i-2)])

    # return λ_

    # BACK SUBSTITUTION
    λ[Block(Nb)] = G[N].U\λ_[Block(Nb)]
    λ[Block(Nb-1)] = H[N-1].U\(λ_[Block(Nb-1)] - F[N]'λ[Block(Nb)])
    λ[Block(Nb-2)] = G[N-1].U\(λ_[Block(Nb-2)] - M[N-1]'λ[Block(Nb-1)] - E[N]'λ[Block(Nb)])

    i = Nb-3
    for k = N-2:-1:1
        λ[Block(i)] = H[k].U\(λ_[Block(i)] - F[k+1]'λ[Block(i+1)] - L[k+1]'λ[Block(i+2)])
        i -= 1
        λ[Block(i)] = G[k].U\(λ_[Block(i)] - M[k]'λ[Block(i+1)] - E[k+1]'λ[Block(i+2)] - K[k+1]'λ[Block(i+3)])
        i -= 1
    end
    λ[Block(1)] = G0.U\(λ_[Block(1)] - F[1]'λ[Block(2)] - L[1]'λ[Block(3)])

    return λ, λ_, r

end


function jacobian_permutation(prob::Problem, solver::ProjectedNewtonSolver)
    n,m,N = size(prob)
    inds = collect(1:length(solver.y))
    p = num_constraints(prob)
    pcum = insert!(cumsum(p),1,0)

    off = n
    for k = 1:N-1
        off1 = n + (k-1)*n
        off2 = N*n + pcum[k]
        println(off1, " ", off2)
        inds[off .+ (1:n)] = off1 .+ (1:n)
        off += n
        inds[off .+ (1:p[k])] = off2 .+ (1:p[k])
        off += p[k]
    end
    return inds
end






function gen_usrfun_newton(prob::Problem)
    n,m,N = size(prob)
    NN = N*n + (N-1)*m
    p_colloc = n*N  # Include initial condition
    p = num_constraints(prob)
    pcum = insert!(cumsum(p), 1, 0)
    P = sum(p) + p_colloc
    part_f = create_partition2(prob.model)
    part_z = create_partition(n,m,N)
    part = (x=1:n, u=n .+ (1:m))
    part2 = (xx=(part.x,part.x), uu=(part.u,part.u),
             xu=(part.x,part.u), ux=(part.u,part.x))
    solver = ProjectedNewtonSolver(prob)

    mycost(V::Union{Primals,PrimalDual}) = cost(prob.obj, V.X, V.U)
    mycost(Z::AbstractVector) = mycost(Primals(Z, part_z))
    function grad_cost(g, V::PrimalDual)
        g_ = reshape(view(g,1:(N-1)*(n+m)), n+m, N-1)
        gterm = view(g,NN-n+1:NN)
        for k = 1:N-1
            grad = PartedArray(view(g_,:,k), part)
            gradient!(grad, prob.obj.cost[k], V.X[k], V.U[k])
        end
        g_ ./= N-1
        gradient!(gterm, prob.obj.cost[N], V.X[N])
    end
    function grad_cost(V::PrimalDual)
        g = zeros(NN)
        grad_cost(g, V)
        return g
    end

    function hess_cost(H, V::PrimalDual)
        off = 0
        for k = 1:N-1
            hess = PartedArray(view(H,off .+ (1:n+m), off .+ (1:n+m)), part2)
            hessian!(hess, prob.obj.cost[k], V.X[k], V.U[k])
            off += n+m
        end
        H ./= N-1
        hess = PartedArray(view(H,off .+ (1:n), off .+ (1:n)), part2)
        hessian!(hess, prob.obj.cost[N], V.X[N])
    end
    function hess_cost(V::PrimalDual)
        H = spzeros(NN,NN)
        hess_cost(H, V)
        return H
    end

    function dynamics(V::Union{Primals,PrimalDual})
        d = zeros(eltype(V.X[1]),p_colloc)
        dynamics(d, V)
        return d
    end
    function dynamics(d, V::Union{PrimalDual,Primals})
        d_ = reshape(d,n,N)
        d_[:,1] = V.X[1] - prob.x0
        for k = 2:N
            xdot = view(d_,:,k)
            evaluate!(xdot, prob.model, V.X[k-1], V.U[k-1], prob.dt)
            xdot .-= V.X[k]
        end
    end
    dynamics(Z::AbstractVector) = dynamics(Primals(Z, part_z))

    function jacob_dynamics(jacob, V::Union{PrimalDual,Primals})
        xdot = zeros(n)
        jacob[1:n,1:n] = Diagonal(I,n)
        off1 = n
        off2 = 0
        block = PartedMatrix(prob.model)
        jacob[1:n,1:n] = Diagonal(I,n)
        for k = 2:N
            jacobian!(block, prob.model, V.X[k-1], V.U[k-1], prob.dt)
            Jx = view(jacob, off1 .+ part.x, off2 .+ part.x)
            Ju = view(jacob, off1 .+ part.x, off2 .+ part.u)
            copyto!(Jx, block.xx)
            copyto!(Ju, block.xu)
            jacob[off1 .+ part.x, (off2+n+m) .+ part.x] = -Diagonal(I,n)
            off1 += n
            off2 += n+m
        end
    end
    function jacob_dynamics(V::Union{PrimalDual,Primals})
        jacob = spzeros(p_colloc, NN)
        jacob_dynamics(jacob, V)
        return jacob
    end


    function constraints(C, V::PrimalDual)
        update_constraints!(prob, solver, V)

        for k = 1:N
            C[pcum[k] .+ (1:p[k])] .= solver.C[k]
        end
    end
    function constraints(V::PrimalDual)
        C = zeros(sum(p))
        constraints(C, V)
        return C
    end

    function jacob_con(∇C, V::PrimalDual)

        off1 = 0
        off2 = 0
        for k = 1:N-1
            jacobian!(solver.∇C[k], prob.constraints[k], V.X[k], V.U[k])
            ∇C[off1 .+ (1:p[k]), off2 .+ (1:n+m)] .= solver.∇C[k]
            off1 += p[k]
            off2 += n+m
        end
        jacobian!(solver.∇C[N], prob.constraints[N], V.X[N])
        ∇C[off1 .+ (1:p[N]), off2 .+ (1:n)] .= solver.∇C[N]
    end
    function jacob_con(V::PrimalDual)
        ∇C = spzeros(sum(p), NN)
        jacob_con(∇C, V)
        return ∇C
    end

    function act_set(V::PrimalDual, tol=solver.opts.active_set_tolerance)
        update_constraints!(prob, solver)
        active_set!(prob, solver)
    end


    return mycost, grad_cost, hess_cost, dynamics, jacob_dynamics, constraints, jacob_con, act_set
end


function projection2!(prob::Problem, V::PrimalDual, tol=1e-3)
    n,m,N = size(prob)
    NN = N*n + (N-1)*m
    p_colloc = n*N
    P = sum(num_constraints(prob)) + p_colloc

    V_ = copy(V)
    Z_ = primals(V_)

    mycost, grad_cost, hess_cost, dyn, jacob_dynamics, con, jacob_con, act_set =
        gen_usrfun_newton(prob)

    act_set(V_,tol)
    a = V_.active_set
    d1 = dyn(V_)
    c1 = con(V_)
    y = [d1; c1][a]
    δZ = zeros(NN)
    println("\nProjection Step:")
    println("max y: ", norm(y, Inf))
    # println("max residual: ", norm(grad_cost(V_) + jacob_dynamics(V_)'duals(V_)))
    count = 0
    while norm(y,Inf) > 1e-10
        D = jacob_dynamics(V_)
        C = jacob_con(V_)
        Y = [D; C][a,:]

        δZ = -Y'*((Y*Y')\y)
        Z_ .+= δZ

        d_ = dyn(V_)
        c_ = con(V_)
        y = [d_; c_][a]
        println("max y: ", norm(y,Inf))
        count += 1
        if count > 10
            break
        end
    end
    println("count: ", count)
end

function newton_step0(prob::Problem, V::PrimalDual, tol=1e-3)

    n,m,N = size(prob)
    NN = N*n + (N-1)*m
    p_colloc = n*N
    P = sum(num_constraints(prob)) + p_colloc

    V_ = copy(V)
    Z_ = primals(V_)

    mycost, grad_cost, hess_cost, dyn, jacob_dynamics, con, jacob_con, act_set =
        gen_usrfun_newton(prob)

    act_set(V_,tol)
    a = V_.active_set
    d1 = dyn(V_)
    c1 = con(V_)
    y = [d1; c1][a]
    δZ = zeros(NN)
    println("\nProjection Step:")
    println("max y: ", norm(y, Inf))
    # println("max residual: ", norm(grad_cost(V_) + jacob_dynamics(V_)'duals(V_)))
    count = 0
    while norm(y,Inf) > 1e-10
        D = jacob_dynamics(V_)
        C = jacob_con(V_)
        Y = [D; C][a,:]

        δZ = -Y'*((Y*Y')\y)
        Z_ .+= δZ

        d_ = dyn(V_)
        c_ = con(V_)
        y = [d_; c_][a]
        println("max y: ", norm(y,Inf))
        count += 1
        if count > 10
            break
        end
    end
    println("count: ", count)

    J0 = mycost(V_)

    # Build and solve KKT
    act_set(V_, tol)
    a = V_.active_set
    d = dyn(V_)
    c = con(V_)
    D = jacob_dynamics(V_)
    C = jacob_con(V_)
    y = [d; c][a]
    Y = [D; C][a,:]
    g = grad_cost(V_) + Y'duals(V_)[a]
    H = hess_cost(V_)
    res0 = norm(g + Y'duals(V_)[a])

    println("\nNewton Step")
    println("Initial Cost: $J0")
    println("max y: ", norm(y, Inf))
    println("residual: ", res0)

    Pa = sum(a)
    aa = [ones(Bool, NN); a]
    A = [H Y'; Y zeros(Pa,Pa)]
    b = [g; y]
    δV = zero(V.V)
    @show cond(Array(Y*Y'))
    δV[aa] = -A\b
    err = A*δV[aa] + b
    println("err: ", norm(err))
    println("max r: ", norm(b))

    return δV


    V1 = copy(V_)
    Z1 = primals(V1)
    V1.V .= V_.V + δV

    D = jacob_dynamics(V_)
    C = jacob_con(V_)
    Y = [D; C][a,:]
    res = norm(grad_cost(V1) + Y'duals(V1)[a])
    println("residual: ", res)
    println("New Cost: ", mycost(V1))
    println("max y: ", norm(dyn(V1), Inf))


    # Line search
    println("\nLine Search")
    ϕ=0.01
    α = 2
    V1 = copy(V_)
    Z1 = primals(V1)
    δV1 = α.*δV
    J = J0+1e8
    res = 1e+8
    r = Inf
    while J > J0 && r > norm(b)
        α *= 0.5
        δV1 = α.*δV
        V1.V .= V_.V + δV1

        act_set(V_, tol)
        d1 = dyn(V1)
        c1 = con(V1)
        y = [d1; c1][a]
        println("max y: ", norm(y, Inf))
        while norm(y, Inf) > 1e-6
            D = jacob_dynamics(V_)
            C = jacob_con(V_)
            Y = [D; C][a,:]
            δZ = -Y'*((Y*Y')\y)
            Z1 .+= δZ

            d1 = dyn(V1)
            c1 = con(V1)
            y1 = [d1; c1][a]
            y = y1
            println("max y: ", norm(y,Inf))
        end

        J = mycost(V1)
        print("New Cost: $J")
        res = norm(grad_cost(V1) + Y'duals(V1)[a])
        println("\t\tmax residual: ", res)
        r = norm([grad_cost(V1); d])
        println("\t\tmax r: $r")
    end
    println("α: ", α)

    # Multiplier projection
    ∇J = grad_cost(V1)
    d = dyn(V1)
    y = d
    D = jacob_dynamics(V1)
    C = jacob_con(V1)
    Y = [D; C][a,:]

    lambda = duals(V1)[a]
    res = ∇J + Y'lambda
    println("\nMultipler Projection")
    println("max y ", norm(y, Inf))
    println("max residual before: ", norm(res))
    δlambda = -(Y*Y')\(Y*res)
    lambda1 = lambda + δlambda
    r = ∇J + Y'lambda1
    println("max residual after: ", norm(r))
    V1.Y[a] .= lambda1
    J = mycost(V1)
    println("New Cost: $J")
    return V1
end

function solve(prob::Problem, opts::ProjectedNewtonSolverOptions)::Problem
    solver = ProjectedNewtonSolver(prob, opts)
    V = solver.V
    V1 = newton_step0(prob, V, opts.active_set_tolerance)
    res = copy(prob)
    copyto!(res.X, V1.X)
    copyto!(res.U, V1.U)
    # projection!(res)
    return res
end

# function calc_violations(solver::Union{AugmentedLagrangianSolver{T}, ProjectedNewtonSolver{T}}) where T
#     c_max = 0.0
#     C = solver.C
#     N = length(C)
#     p = length.(C)
#     v = [zeros(pi) for pi in p]
#     for k = 1:N
#         v[k][C[k].parts[:equality]] = abs.(C[k].equality)
#         if length(C[k].inequality) > 0
#             v[k][C[k].parts[:inequality]] = max.(C[k].inequality, 0)
#         end
#     end
#     return v
# end

# function residual(prob::Problem, solver::ProjectedNewtonSolver)
#     g = vcat([[q.x; q.u] for q in solver.Q]...)
#     d = vcat(solver.fVal...)
#     return norm([g;d]), norm(g), norm(d)
# end


function dynamics_expansion(prob::Problem, solver::ProjectedNewtonSolver)
    n,m,N = size(prob)
    NN = N*n + (N-1)*m
    D = spzeros(N*n, NN)
    d = zeros(N*n)

    off1,off2 = n,0
    part = (x=1:n, u=n .+ (1:m), z=1:n+m, x2=n+m .+ (1:n))
    d[part.x] = solver.fVal[1]
    D[part.x, part.z] = solver.∇F[1]
    for k = 2:N
        D[off1 .+ (part.x), off2 .+ (part.z)] = solver.∇F[k]
        D[off1 .+ (part.x), off2 .+ (part.x2)] = -Diagonal(I,n)
        d[off1 .+ (part.x)] = solver.fVal[k]
        off1 += n
        off2 += n+m
    end
    return D,d
end
