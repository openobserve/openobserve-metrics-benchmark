#!/usr/bin/env bash
# The four PromQL expressions under test, exactly as in the article.
#
# Sourced by run-benchmark.sh AFTER config.sh, because the two filtered queries
# interpolate ${PATH_FILTER}.
#
# QUERY_IDS is the report order. build_query <id> prints the PromQL.

QUERY_IDS=(
  irate
  histogram-unfiltered
  histogram-regex
  histogram-equality
)

build_query() {
  case "$1" in
    # 1. irate over the histogram's _count series (41,760 series in the
    #    published run). The everyday "request rate by endpoint" panel.
    irate)
      printf 'sum by (path) (irate(codelab_api_request_duration_seconds_count[1m]))'
      ;;

    # 2. Unfiltered histogram over ALL _bucket series (1,085,760 in the
    #    published run). No label filter at all -- the stress test. Prometheus
    #    and Mimir are expected to return errors here on the wider windows;
    #    that is a result, not a broken run.
    histogram-unfiltered)
      printf 'histogram_quantile(0.9, sum by(le, path) (rate(codelab_api_request_duration_seconds_bucket{}[5m])))'
      ;;

    # 3. Same histogram, regex-matched on one path.
    histogram-regex)
      printf 'histogram_quantile(0.9, sum by(le, path) (rate(codelab_api_request_duration_seconds_bucket{path=~"%s"}[5m])))' "${PATH_FILTER}"
      ;;

    # 4. Same histogram, equality-matched on the same path. The point of running
    #    both is to show the filter TYPE barely matters -- scan volume does.
    histogram-equality)
      printf 'histogram_quantile(0.9, sum by(le, path) (rate(codelab_api_request_duration_seconds_bucket{path="%s"}[5m])))' "${PATH_FILTER}"
      ;;

    *)
      echo "unknown query id: $1" >&2
      return 1
      ;;
  esac
}
