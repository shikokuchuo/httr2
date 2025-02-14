#' Perform a request to get a response
#'
#' @description
#' After preparing a [request], call `req_perform()` to perform it, fetching
#' the results back to R as a [response].
#'
#' The default HTTP method is `GET` unless a body (set by [req_body_json] and
#' friends) is present, in which case it will be `POST`. You can override
#' these defaults with [req_method()].
#'
#' # Requests
#' Note that one call to `req_perform()` may perform multiple HTTP requests:
#'
#' * If the `url` is redirected with a 301, 302, 303, or 307, curl will
#'   automatically follow the `Location` header to the new location.
#'
#' * If you have configured retries with [req_retry()] and the request
#'   fails with a transient problem, `req_perform()` will try again after
#'   waiting a bit. See [req_retry()] for details.
#'
#' * If you are using OAuth, and the cached token has expired, `req_perform()`
#'   will get a new token either using the refresh token (if available)
#'   or by running the OAuth flow.
#'
#' # Progress bar
#'
#' `req_perform()` will automatically add a progress bar if it needs to wait
#' between requests for [req_throttle()] or [req_retry()]. You can turn the
#' progress bar off (and just show the total time to wait) by setting
#' `options(httr2_progress = FALSE)`.
#'
#' @param req A httr2 [request] object.
#' @param path Optionally, path to save body of the response. This is useful
#'   for large responses since it avoids storing the response in memory.
#' @param mock A mocking function. If supplied, this function is called
#'   with the request. It should return either `NULL` (if it doesn't want to
#'   handle the request) or a [response] (if it does). See [with_mock()]/
#'   `local_mock()` for more details.
#' @param verbosity How much information to print? This is a wrapper
#'   around [req_verbose()] that uses an integer to control verbosity:
#'
#'   * `0`: no output
#'   * `1`: show headers
#'   * `2`: show headers and bodies
#'   * `3`: show headers, bodies, and curl status messages.
#'
#'   Use [with_verbosity()] to control the verbosity of requests that
#'   you can't affect directly.
#' @inheritParams rlang::args_error_context
#' @returns
#'   * If the HTTP request succeeds, and the status code is ok (e.g. 200),
#'     an HTTP [response].
#'
#'   * If the HTTP request succeeds, but the status code is an error
#'     (e.g a 404), an error with class `c("httr2_http_404", "httr2_http")`.
#'     By default, all 400 and 500 status codes will be treated as an error,
#'     but you can customise this with [req_error()].
#'
#'   * If the HTTP request fails (e.g. the connection is dropped or the
#'     server doesn't exist), an error with class `"httr2_failure"`.
#' @export
#' @seealso [req_perform_parallel()] to perform multiple requests in parallel.
#'   [req_perform_iterative()] to perform multiple requests iteratively.
#' @examples
#' request("https://google.com") |>
#'   req_perform()
req_perform <- function(
      req,
      path = NULL,
      verbosity = NULL,
      mock = getOption("httr2_mock", NULL),
      error_call = current_env()
  ) {
  check_request(req)
  check_string(path, allow_null = TRUE)
  # verbosity checked by req_verbosity
  check_function(mock, allow_null = TRUE)

  verbosity <- verbosity %||% httr2_verbosity()

  if (!is.null(mock)) {
    mock <- as_function(mock)
    mock_resp <- mock(req)
    if (!is.null(mock_resp)) {
      return(handle_resp(req, mock_resp, error_call = error_call))
    }
  }

  req <- req_verbosity(req, verbosity)
  req <- auth_sign(req)

  req <- cache_pre_fetch(req, path)
  if (is_response(req)) {
    return(req)
  }

  req_prep <- req_prepare(req)
  handle <- req_handle(req_prep)
  max_tries <- retry_max_tries(req)
  deadline <- Sys.time() + retry_max_seconds(req)

  n <- 0
  tries <- 0
  reauth <- FALSE # only ever re-authenticate once

  throttle_delay(req)

  delay <- 0
  while (tries < max_tries && Sys.time() < deadline) {
    retry_check_breaker(req, tries, error_call = error_call)
    sys_sleep(delay, "for retry backoff")
    n <- n + 1

    resp <- tryCatch(
      req_perform1(req, path = path, handle = handle),
      error = function(err) {
        error_cnd(
          message = "Failed to perform HTTP request.",
          class = c("httr2_failure", "httr2_error"),
          parent = err,
          request = req,
          call = error_call,
          trace = trace_back()
        )
      }
    )
    req_completed(req_prep)

    if (retry_is_transient(req, resp)) {
      tries <- tries + 1
      delay <- retry_after(req, resp, tries)
      signal(class = "httr2_retry", tries = tries, delay = delay)
    } else if (!reauth && resp_is_invalid_oauth_token(req, resp)) {
      reauth <- TRUE
      req <- auth_sign(req, TRUE)
      req_prep <- req_prepare(req)
      handle <- req_handle(req_prep)
      delay <- 0
    } else {
      # done
      break
    }
  }
  # Used for testing
  signal(class = "httr2_fetch", n = n, tries = tries, reauth = reauth)

  resp <- cache_post_fetch(req, resp, path = path)
  handle_resp(req, resp, error_call = error_call)
}

handle_resp <- function(req, resp, error_call = caller_env()) {
  if (resp_show_body(resp)) {
    show_body(resp$body, resp$headers$`content-type`, prefix = "<< ")
  }

  if (is_error(resp)) {
    cnd_signal(resp)
  } else if (error_is_error(req, resp)) {
    body <- error_body(req, resp, error_call)
    resp_abort(resp, req, body, call = error_call)
  } else {
    resp
  }
}

req_perform1 <- function(req, path = NULL, handle = NULL) {
  the$last_request <- req
  the$last_response <- NULL
  signal(class = "httr2_perform")

  if (!is.null(path)) {
    res <- curl::curl_fetch_disk(req$url, path, handle)
    body <- new_path(path)
  } else {
    res <- curl::curl_fetch_memory(req$url, handle)
    body <- res$content
  }

  # Ensure cookies are saved to disk now, not when request is finalised
  curl::handle_setopt(handle, cookielist = "FLUSH")
  curl::handle_setopt(handle, cookiefile = NULL, cookiejar = NULL)

  resp <- new_response(
    method = req_method_get(req),
    url = res$url,
    status_code = res$status_code,
    headers = as_headers(res$headers),
    body = body,
    request = req
  )
  the$last_response <- resp
  resp
}

req_verbosity <- function(req, verbosity, error_call = caller_env()) {
  if (!is_integerish(verbosity, n = 1) || verbosity < 0 || verbosity > 3) {
    cli::cli_abort("{.arg verbosity} must 0, 1, 2, or 3.", call = error_call)
  }

  switch(verbosity + 1,
    req,
    req_verbose(req),
    req_verbose(req, body_req = TRUE, body_resp = TRUE),
    req_verbose(req, body_req = TRUE, body_resp = TRUE, info = TRUE)
  )
}

#' Retrieve most recent request/response
#'
#' These functions retrieve the most recent request made by httr2 and
#' the response it received, to facilitate debugging problems _after_ they
#' occur. If the request did not succeed (or no requests have been made)
#' `last_response()` will be `NULL`.
#'
#' @returns An HTTP [response]/[request].
#' @export
#' @examples
#' invisible(request("http://httr2.r-lib.org") |> req_perform())
#' last_request()
#' last_response()
last_response <- function() {
  the$last_response
}

#' @export
#' @rdname last_response
last_request <- function() {
  the$last_request
}

# Must call req_prepare(), then req_handle(), then after the request has been
# performed, req_completed()
req_prepare <- function(req) {
  req <- req_method_apply(req)
  req <- req_body_apply(req)

  if (!has_name(req$options, "useragent")) {
    req <- req_user_agent(req)
  }

  req
}
req_handle <- function(req) {
  handle <- curl::new_handle()
  curl::handle_setheaders(handle, .list = headers_flatten(req$headers))
  curl::handle_setopt(handle, .list = req$options)
  if (length(req$fields) > 0) {
    curl::handle_setform(handle, .list = req$fields)
  }

  handle
}
req_completed <- function(req) {
  req_policy_call(req, "done", list(), NULL)
}

new_path <- function(x) structure(x, class = "httr2_path")
is_path <- function(x) inherits(x, "httr2_path")

resp_show_body <- function(resp) {
  resp$request$policies$show_body %||% FALSE
}
