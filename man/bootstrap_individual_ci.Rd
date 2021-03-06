% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/bootstrap_ci.R
\name{bootstrap_individual_ci}
\alias{bootstrap_individual_ci}
\title{Runs the bootstrap estimation method for a single set of coefs (not a list)}
\usage{
bootstrap_individual_ci(
  base_matrix = NULL,
  resampled_coef_list = NULL,
  orig_df = NULL,
  alpha_level = 0.05,
  probs = NULL
)
}
\arguments{
\item{orig_df}{Degrees of freedom to use to calculate the
t-values used for the base interval.}

\item{alpha_level}{level of CI - if you fill in \code{probs}, will use those instead}

\item{probs}{Default \code{NULL}, and will use \code{alpha_level} to set
endpoints. Else will calculate these CI endpoints.}
}
\value{
Returns a matrix result
}
\description{
Runs the bootstrap estimation method for a single set of coefs (not a list)
}
\keyword{internal}
