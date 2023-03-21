module OptimizationNLopt

using Reexport
@reexport using NLopt, Optimization
using Optimization.SciMLBase

(f::NLopt.Algorithm)() = f

SciMLBase.allowsbounds(opt::Union{NLopt.Algorithm, NLopt.Opt}) = true

function __map_optimizer_args!(prob::OptimizationProblem, opt::NLopt.Opt;
                               callback = nothing,
                               maxiters::Union{Number, Nothing} = nothing,
                               maxtime::Union{Number, Nothing} = nothing,
                               abstol::Union{Number, Nothing} = nothing,
                               reltol::Union{Number, Nothing} = nothing,
                               local_method::Union{NLopt.Algorithm, NLopt.Opt, Nothing} = nothing,
                               local_maxiters::Union{Number, Nothing} = nothing,
                               local_maxtime::Union{Number, Nothing} = nothing,
                               local_options::Union{NamedTuple, Nothing} = nothing,
                               kwargs...)
    if local_method !== nothing
        if isa(local_method, NLopt.Opt)
            if ndims(local_method) != length(prob.u0)
                error("Passed local NLopt.Opt optimization dimension does not match OptimizationProblem dimension.")
            end
            local_meth = local_method
        else
            local_meth = NLopt.Opt(local_method, length(prob.u0))
        end

        if !isnothing(local_options)
            for j in Dict(pairs(local_options))
                eval(Meta.parse("NLopt." * string(j.first) * "!"))(local_meth, j.second)
            end
        end

        if !(isnothing(local_maxiters))
            NLopt.maxeval!(local_meth, local_maxiters)
        end

        if !(isnothing(local_maxtime))
            NLopt.maxtime!(local_meth, local_maxtime)
        end

        NLopt.local_optimizer!(opt, local_meth)
    end

    # add optimiser options from kwargs
    for j in kwargs
        eval(Meta.parse("NLopt." * string(j.first) * "!"))(opt, j.second)
    end

    if prob.ub !== nothing
        opt.upper_bounds = prob.ub
    end

    if prob.lb !== nothing
        opt.lower_bounds = prob.lb
    end

    if !(isnothing(maxiters))
        NLopt.maxeval!(opt, maxiters)
    end

    if !(isnothing(maxtime))
        NLopt.maxtime!(opt, maxtime)
    end

    if !isnothing(abstol)
        NLopt.ftol_abs!(opt, abstol)
    end
    if !isnothing(reltol)
        NLopt.ftol_rel!(opt, reltol)
    end

    return nothing
end

function __nlopt_status_to_ReturnCode(status::Symbol)
    if status in Symbol.([
                             NLopt.SUCCESS,
                             NLopt.STOPVAL_REACHED,
                             NLopt.FTOL_REACHED,
                             NLopt.XTOL_REACHED,
                             NLopt.ROUNDOFF_LIMITED,
                         ])
        return ReturnCode.Success
    elseif status == Symbol(NLopt.MAXEVAL_REACHED)
        return ReturnCode.MaxIters
    elseif status == Symbol(NLopt.MAXTIME_REACHED)
        return ReturnCode.MaxTime
    elseif status in Symbol.([
                                 NLopt.OUT_OF_MEMORY,
                                 NLopt.INVALID_ARGS,
                                 NLopt.FAILURE,
                                 NLopt.FORCED_STOP,
                             ])
        return ReturnCode.Failure
    else
        return ReturnCode.Default
    end
end

function SciMLBase.__solve(prob::OptimizationProblem,
                           opt::Union{NLopt.Algorithm, NLopt.Opt};
                           maxiters::Union{Number, Nothing} = nothing,
                           maxtime::Union{Number, Nothing} = nothing,
                           local_method::Union{NLopt.Algorithm, NLopt.Opt, Nothing} = nothing,
                           local_maxiters::Union{Number, Nothing} = nothing,
                           local_maxtime::Union{Number, Nothing} = nothing,
                           local_options::Union{NamedTuple, Nothing} = nothing,
                           abstol::Union{Number, Nothing} = nothing,
                           reltol::Union{Number, Nothing} = nothing,
                           progress = false,
                           callback = (args...) -> (false),
                           kwargs...)
    local x

    maxiters = Optimization._check_and_convert_maxiters(maxiters)
    maxtime = Optimization._check_and_convert_maxtime(maxtime)
    local_maxiters = Optimization._check_and_convert_maxiters(local_maxiters)
    local_maxtime = Optimization._check_and_convert_maxtime(local_maxtime)

    f = Optimization.instantiate_function(prob.f, prob.u0, prob.f.adtype, prob.p)

    _loss = function (θ)
        x = f.f(θ, prob.p)
        callback(θ, x...)
        return x[1]
    end

    fg! = function (θ, G)
        if length(G) > 0
            f.grad(G, θ)
        end

        return _loss(θ)
    end

    if isa(opt, NLopt.Opt)
        if ndims(opt) != length(prob.u0)
            error("Passed NLopt.Opt optimization dimension does not match OptimizationProblem dimension.")
        end
        opt_setup = opt
    else
        opt_setup = NLopt.Opt(opt, length(prob.u0))
    end

    prob.sense === Optimization.MaxSense ? NLopt.max_objective!(opt_setup, fg!) :
    NLopt.min_objective!(opt_setup, fg!)

    __map_optimizer_args!(prob, opt_setup, maxiters = maxiters, maxtime = maxtime,
                          abstol = abstol, reltol = reltol, local_method = local_method,
                          local_maxiters = local_maxiters, local_options = local_options;
                          kwargs...)

    t0 = time()
    (minf, minx, ret) = NLopt.optimize(opt_setup, prob.u0)
    t1 = time()

    retcode = __nlopt_status_to_ReturnCode(ret)

    if retcode == ReturnCode.Failure
        @warn "NLopt failed to converge: $(ret)"
        minx = fill(NaN, length(prob.u0))
        minf = NaN
    end

    SciMLBase.build_solution(SciMLBase.DefaultOptimizationCache(prob.f, prob.p), opt, minx,
                             minf; original = opt_setup, retcode = retcode,
                             solve_time = t1 - t0)
end

end
