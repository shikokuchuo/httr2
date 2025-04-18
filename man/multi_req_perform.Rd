% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/req-perform-parallel.R
\name{multi_req_perform}
\alias{multi_req_perform}
\title{Perform a list of requests in parallel}
\usage{
multi_req_perform(
  reqs,
  paths = NULL,
  pool = deprecated(),
  cancel_on_error = FALSE
)
}
\arguments{
\item{reqs}{A list of \link{request}s.}

\item{paths}{An optional character vector of paths, if you want to download
the response bodies to disk. If supplied, must be the same length as
\code{reqs}.}

\item{pool}{\ifelse{html}{\href{https://lifecycle.r-lib.org/articles/stages.html#deprecated}{\figure{lifecycle-deprecated.svg}{options: alt='[Deprecated]'}}}{\strong{[Deprecated]}}. No longer supported;
to control the maximum number of concurrent requests, set \code{max_active}.}

\item{cancel_on_error}{Should all pending requests be cancelled when you
hit an error? Set this to \code{TRUE} to stop all requests as soon as you
hit an error. Responses that were never performed be \code{NULL} in the result.}
}
\description{
\ifelse{html}{\href{https://lifecycle.r-lib.org/articles/stages.html#deprecated}{\figure{lifecycle-deprecated.svg}{options: alt='[Deprecated]'}}}{\strong{[Deprecated]}}

Please use \code{\link[=req_perform_parallel]{req_perform_parallel()}} instead, and note:
\itemize{
\item \code{cancel_on_error = FALSE} is now \code{on_error = "continue"}
\item \code{cancel_on_error = TRUE} is now \code{on_error = "return"}
}
}
\keyword{internal}
