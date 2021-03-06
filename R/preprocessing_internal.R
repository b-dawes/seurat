
globalVariables(names = 'i', package = 'Seurat', add = TRUE)
# Regress out technical effects and cell cycle
#
# Remove unwanted effects from scale.data
#
# @keywords internal
# @param object Seurat object
# @param vars.to.regress effects to regress out
# @param genes.regress gene to run regression for (default is all genes)
# @param model.use Use a linear model or generalized linear model (poisson, negative binomial) for the regression. Options are 'linear' (default), 'poisson', and 'negbinom'
# @param use.umi Regress on UMI count data. Default is FALSE for linear modeling, but automatically set to TRUE if model.use is 'negbinom' or 'poisson'
# @param display.progress display progress bar for regression procedure.
# @param do.par use parallel processing for regressing out variables faster.
# If set to TRUE, will use half of the machines available cores (FALSE by default)
# @param num.cores If do.par = TRUE, specify the number of cores to use.
#
# @return Returns the residuals from the regression model
#
#' @import Matrix
#' @import doSNOW
#' @importFrom stats as.formula lm residuals glm
#' @importFrom utils txtProgressBar setTxtProgressBar
#' @importFrom foreach foreach %dopar%
#
RegressOutResid <- function(
  object,
  vars.to.regress,
  genes.regress = NULL,
  model.use = 'linear',
  use.umi = FALSE,
  display.progress = TRUE,
  do.par = FALSE,
  num.cores = 1
) {
  possible.models <- c("linear", "poisson", "negbinom")
  if (! model.use %in% possible.models){
    stop(
      paste0(
        model.use,
        " is not a valid model. Please use one the following: ",
        paste0(possible.models, collapse = ", "),
        "."
      )
    )
  }
  genes.regress <- SetIfNull(x = genes.regress, default = rownames(x = object@data))
  genes.regress <- intersect(x = genes.regress, y = rownames(x = object@data))
  latent.data <- FetchData(object = object, vars.all = vars.to.regress)
  bin.size <- 100
  if (model.use == 'negbinom') {
    bin.size <- 5
  }
  bin.ind <- ceiling(x = 1:length(x = genes.regress) / bin.size)
  max.bin <- max(bin.ind)
  if(display.progress){
    print(paste("Regressing out", vars.to.regress))
    pb <- txtProgressBar(min = 0, max = max.bin, style = 3)
  }
  data.resid <- c()
  data.use <- object@data[genes.regress, , drop = FALSE];
  if (model.use != "linear") {
    use.umi <- TRUE
  }
  if (use.umi) {
    data.use <- object@raw.data[genes.regress, object@cell.names, drop = FALSE]
  }

  # input checking for parallel options
  if(do.par){
    if(num.cores == 1){
      num.cores <- detectCores() / 2
    } else {
      if(num.cores > detectCores()){
        num.cores <- detectCores() - 1
        warning(paste0("num.cores set greater than number of available cores(", detectCores(), "). Setting num.cores to ", num.cores, "."))
      }
    }
  } else {
    if(num.cores != 1){
      num.cores <- 1
      warning("For parallel processing, please set do.par to TRUE.")
    }
  }
  cl<- parallel::makeCluster(num.cores)

  # using doSNOW library because it supports progress bar update
  registerDoSNOW(cl)

  opts <- list()
  if(display.progress)
  {
    # define progress bar function
    progress <- function(n) setTxtProgressBar(pb, n)
    opts <- list(progress = progress)
    time_elapsed <- Sys.time()
  }

  data.resid <- foreach(i = 1:max.bin, .combine = "rbind", .options.snow = opts) %dopar% {
    genes.bin.regress <- rownames(x = data.use)[bin.ind == i]
    gene.expr <- as.matrix(x = data.use[genes.bin.regress, , drop = FALSE])
    new.data <- do.call(
      rbind,
      lapply(
        X = genes.bin.regress,
        FUN = function(x) {
          regression.mat <- cbind(latent.data, gene.expr[x,])
          colnames(x = regression.mat) <- c(colnames(x = latent.data), "GENE")
          fmla <- as.formula(
            object = paste0(
              "GENE ",
              " ~ ",
              paste(vars.to.regress, collapse = "+")
            )
          )
          if (model.use == 'linear') {
            return(lm(formula = fmla, data = regression.mat)$residuals)
          }
          if (model.use == 'poisson') {
            return(residuals(
              object = glm(
                formula = fmla,
                data = regression.mat,
                family = "poisson"
              ),
              type='pearson'
            ))
          }
          if (model.use == 'negbinom') {
            return(NBResiduals(
              fmla = fmla,
              regression.mat = regression.mat,
              gene = x
            ))
          }
        }
      )
    )
    new.data
  }

  if (display.progress) {
    time_elapsed <- Sys.time() - time_elapsed
    cat(paste("\nTime Elapsed: ",time_elapsed, units(time_elapsed)))
    close(pb)
  }

  stopCluster(cl)

  rownames(x = data.resid) <- genes.regress
  if (use.umi) {
    data.resid <- log1p(
      x = sweep(
        x = data.resid,
        MARGIN = 1,
        STATS = apply(X = data.resid, MARGIN = 1, FUN = min),
        FUN = "-"
      )
    )
  }
  return(data.resid)
}

# Regress out technical effects and cell cycle using regularized Negative Binomial regression
#
# Remove unwanted effects from umi data and set scale.data to Pearson residuals
# Uses mclapply; you can set the number of cores it will use to n with command options(mc.cores = n)
#
# @param object Seurat object
# @param latent.vars effects to regress out
# @param genes.regress gene to run regression for (default is all genes)
# @param pr.clip.range numeric of length two specifying the min and max values the results will be clipped to
#
# @return Returns Seurat object with the scale.data (object@scale.data) genes returning the residuals fromthe regression model
#
#' @import Matrix
#' @import parallel
#' @importFrom stats glm residuals
#' @importFrom MASS theta.ml negative.binomial
#' @importFrom utils txtProgressBar setTxtProgressBar
#
RegressOutNB <- function(
  object,
  latent.vars,
  genes.regress = NULL,
  pr.clip.range = c(-30, 30),
  min.theta = 0.01
) {
  genes.regress <- SetIfNull(x = genes.regress, default = rownames(x = object@data))
  genes.regress <- intersect(x = genes.regress, y = rownames(x = object@data))
  cm <- object@raw.data[genes.regress, colnames(x = object@data), drop = FALSE]
  latent.data <- FetchData(object = object, vars.all = latent.vars)
  cat(sprintf('Regressing out %s for %d genes\n', paste(latent.vars), length(x = genes.regress)))
  theta.fit <- RegularizedTheta(cm = cm, latent.data = latent.data, min.theta = 0.01, bin.size = 128)
  print('Second run NB regression with fixed theta')
  bin.size <- 128
  bin.ind <- ceiling(1:length(genes.regress)/bin.size)
  max.bin <- max(bin.ind)
  pb <- txtProgressBar(min = 0, max = max.bin, style = 3)
  pr <- c()
  for (i in 1:max.bin) {
    genes.bin.regress <- genes.regress[bin.ind == i]
    bin.pr.lst <- parallel::mclapply(
      X = genes.bin.regress,
      FUN = function(j) {
        fit <- 0
        try(
          expr = fit <- glm(
            cm[j, ] ~ .,
            data = latent.data,
            family = MASS::negative.binomial(theta = theta.fit[j])
          ),
          silent=TRUE
        )
        if (class(fit)[1] == 'numeric') {
          message(
            sprintf(
              'glm and family=negative.binomial(theta=%f) failed for gene %s; falling back to scale(log10(y+1))',
              theta.fit[j],
              j
            )
          )
          res <- scale(log10(cm[j, ] + 1))[, 1]
        } else {
          res <- residuals(fit, type = 'pearson')
        }
        return(res)
      }
    )
    pr <- rbind(pr, do.call(rbind, bin.pr.lst))
    setTxtProgressBar(pb, i)
  }
  close(pb)
  dimnames(x = pr) <- dimnames(x = cm)
  pr[pr < pr.clip.range[1]] <- pr.clip.range[1]
  pr[pr > pr.clip.range[2]] <- pr.clip.range[2]
  object@scale.data <- pr
  return(object)
}

# Regress out technical effects and cell cycle using regularized Negative Binomial regression
#
# Remove unwanted effects from umi data and set scale.data to Pearson residuals
# Uses mclapply; you can set the number of cores it will use to n with command options(mc.cores = n)
#
# @param object Seurat object
# @param latent.vars effects to regress out
# @param genes.regress gene to run regression for (default is all genes)
# @param pr.clip.range numeric of length two specifying the min and max values the results will be clipped to
#
# @return Returns Seurat object with the scale.data (object@scale.data) genes returning the residuals from the regression model
#
#' @import Matrix
#' @import parallel
#' @importFrom MASS theta.ml negative.binomial
#' @importFrom stats glm loess residuals
#' @importFrom utils txtProgressBar setTxtProgressBar
#
RegressOutNBreg <- function(
  object,
  latent.vars,
  genes.regress = NULL,
  pr.clip.range = c(-30, 30),
  min.theta = 0.01
) {
  genes.regress <- SetIfNull(x = genes.regress, default = rownames(x = object@data))
  genes.regress <- intersect(x = genes.regress, y = rownames(x = object@data))
  cm <- object@raw.data[genes.regress, colnames(x = object@data), drop=FALSE]
  latent.data <- FetchData(object = object, vars.all = latent.vars)
  bin.size <- 128
  bin.ind <- ceiling(x = 1:length(x = genes.regress) / bin.size)
  max.bin <- max(bin.ind)
  print(paste("Regressing out", latent.vars))
  print('First run Poisson regression (to get initial mean), and estimate theta per gene')
  pb <- txtProgressBar(min = 0, max = max.bin, style = 3)
  theta.estimate <- c()
  for (i in 1:max.bin) {
    genes.bin.regress <- genes.regress[bin.ind == i]
    bin.theta.estimate <- unlist(
      parallel::mclapply(
        X = genes.bin.regress,
        FUN = function(j) {
          as.numeric(
            x = MASS::theta.ml(
              as.numeric(x = unlist(x = cm[j, ])),
              glm(as.numeric(x = unlist(x = cm[j, ])) ~ ., data = latent.data, family=poisson)$fitted
            )
          )
        }
      ),
      use.names = FALSE
    )
    theta.estimate <- c(theta.estimate, bin.theta.estimate)
    setTxtProgressBar(pb, i)
  }
  close(pb)
  UMI.mean <- apply(X = cm, MARGIN = 1, FUN = mean)
  var.estimate <- UMI.mean + (UMI.mean ^ 2) / theta.estimate
  fit <- loess(log10(var.estimate) ~ log10(UMI.mean), span = 0.33)
  theta.fit <- (UMI.mean ^ 2) / (10 ^ fit$fitted - UMI.mean)
  names(x = theta.fit) <- genes.regress
  to.fix <- theta.fit <= min.theta | is.infinite(x = theta.fit)
  if (any(to.fix)) {
    cat(
      'Fitted theta below',
      min.theta,
      'for',
      sum(to.fix),
      'genes, setting them to',
      min.theta,
      '\n'
    )
    theta.fit[to.fix] <- min.theta
  }
  print('Second run NB regression with fixed theta')
  pb <- txtProgressBar(min = 0, max = max.bin, style = 3)
  pr <- c()
  for(i in 1:max.bin) {
    genes.bin.regress <- genes.regress[bin.ind == i]
    names(genes.bin.regress) <- genes.bin.regress
    bin.pr.lst <- parallel::mclapply(
      X = genes.bin.regress,
      FUN = function(j) {
        fit <- 0
        try(
          fit <- glm(
            as.numeric(x = unlist(x = cm[j, ])) ~ .,
            data = latent.data,
            family=MASS::negative.binomial(theta = theta.fit[j])
          ),
          silent=TRUE
        )
        if (class(fit)[1] == 'numeric') {
          message <- 
            sprintf(
              'glm and family=negative.binomial(theta=%f) failed for gene %s; falling back to scale(log10(y+1))',
              theta.fit[j],
              j
            )
          res <- scale(x = log10(as.numeric(x = unlist(x = cm[j, ])) + 1))[, 1]
        } else {
          message <- NULL
          res <- residuals(object = fit, type='pearson')
        }
        return(list(res = res, message = message))
      }
    )
    # Print message to keep track of the genes for which glm failed to converge
    message <- unlist(x = lapply(X = bin.pr.lst, FUN = function(l) { return(l$message) }), use.names = FALSE)
    if(!is.null(x = message)) { message(paste(message, collapse = "\n")) }
    bin.pr.lst <- lapply(X = bin.pr.lst, FUN = function(l) { return(l$res) })
    pr <- rbind(pr, do.call(rbind, bin.pr.lst))
    setTxtProgressBar(pb, i)
  }
  close(pb)
  dimnames(x = pr) <- dimnames(x = cm)
  pr[pr < pr.clip.range[1]] <- pr.clip.range[1]
  pr[pr > pr.clip.range[2]] <- pr.clip.range[2]
  object@scale.data <- pr
  return(object)
}

# Normalize raw data
#
# Normalize count data per cell and transform to centered log ratio
#
# @param data Matrix with the raw count data
# @param custom_function A custom normalization function
# @parm across Which way to we normalize? Choose form 'cells' or 'genes'
#
# @return Returns a matrix with the custom normalization
#
# @import Matrix
#
CustomNormalize <- function(data, custom_function, across) {
  if (class(x = data) == "data.frame") {
    data <- as.matrix(x = data)
  }
  if (class(x = data) != "dgCMatrix") {
    data <- as(object = data, Class = "dgCMatrix")
  }
  margin <- switch(
    EXPR = across,
    'cells' = 2,
    'genes' = 1,
    stop("'across' must be either 'cells' or 'genes'")
  )
  norm.data <- apply(
    X = data,
    MARGIN = margin,
    FUN = custom_function)
  if (margin == 1) {
    norm.data = t(x = norm.data)
  }
  colnames(x = norm.data) <- colnames(x = data)
  rownames(x = norm.data) <- rownames(x = data)
  return(norm.data)
}
