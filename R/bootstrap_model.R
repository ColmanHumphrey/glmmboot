#' computes bootstrap resamples of your data,
#' stores estimates + SEs.
#'
#' By default, this will compute bootstrap resamples
#' and then send them to `bootstrap_ci`
#' for calculation. Note - only use parallel methods if your
#' model is expensive to build, otherwise the overhead won't be worth it.
#'
#' @import methods
#' @import stats
#'
#' @param base_model
#'   The pre-bootstrap model, i.e. the model output
#'   from running a standard model call.
#'   Examples:
#'   base_model <- glmmTMB(y ~ age + (1 | subj),
#'                         data = rel_data, family = binomial)
#'   base_model <- lm(y ~ x, data = xy_frame)
#'
#' @param base_data
#'   The data that was used in the call. You
#'   can leave this to be automatically read, but
#'   I highly recommend supplying it
#'
#' @param resamples
#'   How many resamples of your data do you want to do?
#'   9999 is a reasonable default (see Hesterberg 2015),
#'   but start very small to make sure it works on
#'   your data properly, and to get a rough timing estimate etc.
#'
#' @param return_coefs_instead
#'   Logical, default FALSE: do you want the list of lists
#'   of results for each bootstrap sample (set to TRUE), or the
#'   matrix output of all samples? See return for more details.
#'
#' @param parallelism
#'   What type of parallelism (if any) to use to run the resamples.
#'   Options are:
#'   - "none"      the default
#'   - "future"    to use future.apply (`future`s)
#'   - "parallel"  to use parallel::mclapply
#'
#' @param resample_specific_blocks
#'   Character vector, default NULL. If left NULL,
#'   this algorithm with choose ONE random block to resample over -
#'   the one with the largest entropy (often the one with most levels).
#'   If you wish to
#'   resample over specific random effects as blocks, enter
#'   the names here - can be one, or many. Note that resampling
#'   multiple blocks is in general quite conservative.
#'
#'   If you want to perform case resampling but you DO have
#'   random effects, set resample_specific_blocks to any
#'   non-null value that isn't equal to a random effect
#'   variable name.
#'
#' @param unique_resample_lim
#'   Should be same length as number of random effects (or left NULL).
#'   Do you want to force the resampling to produce a minimum number of
#'   unique values in sampling? Don't make this too big...
#'   Must be named same as rand cols
#'
#' @param narrowness_avoid
#'   Boolean, default TRUE.
#'   If TRUE, will resample n-1 instead of n elements
#'   in the bootstrap (n being either rows, or random effect levels,
#'   depending on existence of random effects). If FALSE, will do
#'   typical size n resampling.
#'
#' @param num_cores
#'   Defaults to parallel::detectCores() - 1 if parallelism = "parallel"
#'
#' @param suppress_sampling_message
#'   Logical, default FALSE. By default, this function
#'   will message the console with the type of bootstrapping:
#'   block resampling over random effects - in which case it'll say
#'   what effect it's sampling over;
#'   case resampling - in which case it'll say as much.
#'   Set TRUE to hide message.
#'
#' @return
#'   By default, returns the output from bootstrap_ci:
#'     - for each set of covariates (usually just the one set,
#'       the conditional model), a mtarix of output, a row for each variable,
#'       including the intercept
#'       (estimate, CIs for boot and base, p-values).
#'   If return_coefs_instead = TRUE, then will instead
#'   return a list of length two:
#'   [[1]] will be a list containing the output for the base model
#'   [[2]] will be a list of length resamples,
#'   each a list of matrices of estimates and standard errors for each model.
#'   This output is useful for error checking, and if you want
#'   to run this function in certain distributed ways.
#'
#' @examples
#' x <- rnorm(20)
#' y <- rnorm(20) + x
#' xy_data = data.frame(x = x, y = y)
#' first_model <- lm(y ~ x, data = xy_data)
#'
#' out_matrix <- bootstrap_model(first_model, base_data = xy_data, 20)
#' out_list <- bootstrap_model(first_model,
#'                             base_data = xy_data,
#'                             resamples = 20,
#'                             return_coefs_instead = TRUE)
#'
#' \donttest{
#'   data(test_data)
#'   library(glmmTMB)
#'   test_formula <- as.formula('y ~ x_var1 + x_var2 + x_var3 + (1|subj)')
#'   test_model <- glmmTMB(test_formula, data = test_data, family = binomial)
#'   output_matrix <- bootstrap_model(test_model, base_data = test_data, 199)
#'
#'   output_lists <- bootstrap_model(test_model,
#'                                   base_data = test_data,
#'                                   resamples = 199,
#'                                   return_coefs_instead = TRUE)
#' }
#'
#' @export
bootstrap_model <- function(base_model,
                            base_data,
                            resamples = 9999,
                            return_coefs_instead = FALSE,
                            parallelism = c("none", "future", "parallel"),
                            resample_specific_blocks = NULL,
                            unique_resample_lim = NULL,
                            narrowness_avoid = TRUE,
                            num_cores = NULL,
                            suppress_sampling_message = FALSE){
    if (missing(base_data) || is.null(base_data)) {
        warning("Please supply data through the argument base_data; ",
                "automatic reading from your model can produce ",
                "unforeseeable bugs.", call. = FALSE)

        if ("model" %in% names(base_model)) {
            base_data <- base_model$model
        } else if ("frame" %in% names(base_model)) {
            base_data <- base_model$frame
        } else if ("frame" %in% slotNames(base_model)) {
            base_data <- base_model@frame
        } else {
            stop("base_data cannot be automatically inferred, ",
                 "please supply data as base_data ",
                 "to this function", call. = FALSE)
        }
    }

    parallelism <- match.arg(parallelism)

    ##------------------------------------

    ## formula processing
    boot_form <- formula(base_model)
    rand_cols <- get_rand(boot_form)

    ## base regression
    base_coef <- coef(summary(base_model))

    ## this is where we have to decide how to get the coefs.
    if (is.matrix(base_coef)) {
        extract_coef <- function(model){
            list(cond = coef(summary(model))[, 1:2, drop = FALSE])
        }

        main_coef_se <- extract_coef(base_model)
    } else {
        if (!list_of_matrices(base_coef)) {
            stop("currently this method needs `coef(summary(base_model))` ",
                 "to be a matrix, or a list of them", call. = FALSE)
        }
        ## only calc not_null once, but local scope the result
        extract_coef <- (function(not_null){
            function(model){
                lapply(coef(summary(model))[not_null], function(coef_mat){
                    coef_mat[, 1:2, drop = FALSE]
                })
            }
        })(not_null = !unlist(lapply(base_coef, is.null)))

        main_coef_se <- extract_coef(base_model)
    }

    ##------------------------------------

    ## deciding on random blocks. Subset of rand_cols:
    if (is.null(resample_specific_blocks)) {
        if(length(rand_cols) > 1){
            entropy_levels <- unlist(lapply(rand_cols, function(rc){
                calc_entropy(base_data[, rc])
            }))
            ## takes the first in a tie, for consistency.
            rand_cols <- rand_cols[which.max(entropy_levels)]
        }
    } else {
        if (sum(rand_cols %in% resample_specific_blocks) == 0 &&
            length(rand_cols) > 0) {
            stop("No random columns from formula found ",
                 "in resample_specific_blocks", call. = FALSE)
        }
        rand_cols <- rand_cols[rand_cols %in% resample_specific_blocks]
    }

    ## if rand_cols is not empty, we'll resample the blocks
    ## if it's empty, we'll do standard case resampling
    if (length(rand_cols) > 0) {
        if (!suppress_sampling_message) {
            message("Performing block resampling, over ",
                    paste(rand_cols, collapse = ", "))
        }

        orig_list <- lapply(rand_cols, function(rand_col){
            base_data[, rand_col]
        })
        all_list <- lapply(orig_list, unique)
        names(orig_list) <- rand_cols
        names(all_list) <- rand_cols

        gen_sample_data <- (function(base_data,
                                     orig_list,
                                     all_list,
                                     rand_cols,
                                     unique_resample_lim,
                                     narrowness_avoid){
            function(){
                sample_list <- gen_sample(all_list,
                                          rand_cols,
                                          unique_resample_lim,
                                          narrowness_avoid)
                base_data[
                    gen_resampling_index(orig_list, sample_list), ]
            }
        })(base_data,
            orig_list,
            all_list,
            rand_cols,
            unique_resample_lim,
            narrowness_avoid)
    } else {
        if (!suppress_sampling_message) {
            message("Performing case resampling (no random effects)")
        }

        gen_sample_data <- (function(base_data,
                                     narrowness_avoid){
            if (narrowness_avoid) {
                return(function(){
                    base_data[sample(nrow(base_data),
                                     nrow(base_data) - 1,
                                     replace = TRUE), ]
                })
            }
            function(){
                base_data[sample(nrow(base_data),
                                 replace = TRUE), ]
            }
        })(base_data, narrowness_avoid)
    }

    bootstrap_coef_est <- (function(base_model, gen_sample_data){
        function(){
            sample_data <- gen_sample_data()
            model_output <- suppressWarnings(update(base_model,
                                                    data = sample_data))
            extract_coef(model_output)
        }
    })(base_model, gen_sample_data)

    ##------------------------------------

    coef_se_list <- bootstrap_runner(bootstrap_coef_est,
                                     resamples,
                                     parallelism,
                                     num_cores)

    ##------------------------------------

    ## some could be errors
    error_ind <- !not_error_check(coef_se_list)

    if (mean(error_ind) > 0.25) {
        warning("There area lot of errors (approx ",
                round(100 * mean(error_ind), 1), "%)")
    }

    ## keep going until solved
    max_redos <- 10L
    redo_iter <- 1L
    while (sum(error_ind) > 0L && redo_iter <= max_redos) {
        message(sum(error_ind), " error(s) to redo")
        redo_iter <- redo_iter + 1L

        coef_se_list[error_ind] <- bootstrap_runner(bootstrap_coef_est,
                                                    sum(error_ind),
                                                    parallelism,
                                                    num_cores)

        error_ind <- !not_error_check(coef_se_list)
    }
    if (any(error_ind)) {
        warning("could not generate error-free resamples in ",
                max_redos, " attempts; returning ", sum(error_ind),
                " error(s) out of ", resamples, " total",
                call. = FALSE)
    }

    if (return_coefs_instead) {
        return(list(base_coef_se = main_coef_se,
                    resampled_coef_se = coef_se_list))
    }

    ## We won't dive too far into the world of dfs,
    ## we'll basically default to z-values (Inf df) if not clear
    if ("df.residual" %in% names(base_model)) {
        orig_df <- base_model$df.residual
    } else {
        orig_df <- Inf
    }

    bootstrap_ci(base_coef_se = main_coef_se,
                 resampled_coef_se = coef_se_list,
                 orig_df = orig_df)
}

#' @export
#' @rdname bootstrap_model
#' @param suppress_loading_bar
#' defunct now
#' @param allow_conv_error
#' defunct now
BootGlmm <- function(base_model,
                     resamples = 9999,
                     base_data = NULL,
                     return_coefs_instead = FALSE,
                     resample_specific_blocks = NULL,
                     unique_resample_lim = NULL,
                     narrowness_avoid = TRUE,
                     num_cores = NULL,
                     suppress_sampling_message = FALSE,
                     suppress_loading_bar = FALSE,
                     allow_conv_error = FALSE){
    .Deprecated("bootstrap_model")

    bootstrap_model(base_model = base_model,
                    base_data = base_data,
                    resamples = resamples,
                    return_coefs_instead = return_coefs_instead,
                    resample_specific_blocks = resample_specific_blocks,
                    unique_resample_lim = unique_resample_lim,
                    narrowness_avoid = narrowness_avoid,
                    num_cores = num_cores,
                    suppress_sampling_message = suppress_sampling_message)
}

#' Runs the bootstrapping of the models
#'
#' This function gets passed a function that runs a single bootstrap resample
#' and a number of resamples, and decides how to run them
#' e.g. in parallel etc
#'
#' @param bootstrap_function
#'   a function that we wish to run `resamples` times
#'
#' @param resamples
#'   how many times we wish to run `bootstrap_function`
#'
#' @param parallelism
#'   How to run this function in parallel
#'
#' @param num_cores
#'   How many cores to use, if using `parallel`
#'
#' @return
#'   returns the list that contains the results of running
#'   `bootstrap_function`.
#'
#' @keywords internal
bootstrap_runner <- function(bootstrap_function,
                             resamples,
                             parallelism = c("none", "future", "parallel"),
                             num_cores = NULL){
    parallelism <- match.arg(parallelism)

    if (parallelism == "future") {
        if (requireNamespace("future.apply", quietly = TRUE)) {
            return(future.apply::future_lapply(
                                     1:resamples,
                                     function(i){
                                         bootstrap_function()
                                     }))
        }
        warning("future.apply not installed, using base lapply",
                call. = FALSE)
        parallelism <- "none"
    }

    if (parallelism == "parallel") {
        if (requireNamespace("parallel", quietly = TRUE)) {
            if (is.null(num_cores)) {
                num_cores <- parallel::detectCores() - 1
            }

            return(parallel::mclapply(1:resamples,
                                      function(i){
                                          bootstrap_function()
                                      },
                                      mc.cores = num_cores,
                                      mc.preschedule = FALSE))
        }
        warning("parallel not installed, using base lapply",
                call. = FALSE)
        parallelism <- "none"
    }

    lapply(1:resamples, function(i) bootstrap_function())
}