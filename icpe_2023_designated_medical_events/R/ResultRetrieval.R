


renderTranslateQuerySql <-
  function(connection,
           sql,
           dbms,
           ...,
           snakeCaseToCamelCase = FALSE) {
    if (is(connection, "Pool")) {
      sql <- SqlRender::render(sql, ...)
      sql <- SqlRender::translate(sql, targetDialect = dbms)

      tryCatch(
        {
          data <- DatabaseConnector::dbGetQuery(connection, sql)
        },
        error = function(err) {
          writeLines(sql)
          if (dbms %in% c("postgresql", "redshift")) {
            DatabaseConnector::dbExecute(connection, "ABORT;")
          }
          stop(err)
        }
      )
      if (snakeCaseToCamelCase) {
        colnames(data) <- SqlRender::snakeCaseToCamelCase(colnames(data))
      }
      return(data)
    } else {
      return(
        DatabaseConnector::renderTranslateQuerySql(
          connection = connection,
          sql = sql,
          ...,
          snakeCaseToCamelCase = snakeCaseToCamelCase
        )
      )
    }
  }


queryResultCovariateValue <- function(dataSource,
                                      cohortIds,
                                      analysisIds = NULL,
                                      databaseIds,
                                      startDay = NULL,
                                      endDay = NULL,
                                      temporalCovariateValue = TRUE,
                                      temporalCovariateValueDist = TRUE,
                                      meanThreshold = 0) {
  # Perform error checks for input variables
  errorMessage <- checkmate::makeAssertCollection()
  checkmate::assertIntegerish(
    x = startDay,
    any.missing = TRUE,
    unique = FALSE,
    null.ok = TRUE,
    add = errorMessage
  )
  checkmate::assertIntegerish(
    x = endDay,
    any.missing = TRUE,
    unique = FALSE,
    null.ok = TRUE,
    add = errorMessage
  )

  temporalTimeRefData <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      dbms = dataSource$dbms,
      sql = "SELECT *
             FROM @results_database_schema.@table_name
             WHERE (time_id IS NOT NULL AND time_id != 0)
              {@start_day != \"\"} ? { AND start_day IN (@start_day)}
              {@end_day != \"\"} ? { AND end_day IN (@end_day)};",
      snakeCaseToCamelCase = TRUE,
      results_database_schema = dataSource$resultsDatabaseSchema,
      table_name = dataSource$prefixTable("temporal_time_ref"),
      start_day = startDay,
      end_day = endDay
    ) %>%
    dplyr::tibble()

  temporalTimeRefData <- dplyr::bind_rows(
    temporalTimeRefData,
    dplyr::tibble(timeId = -1)
  )

  temporalAnalysisRefData <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      dbms = dataSource$dbms,
      sql = "SELECT *
             FROM @results_database_schema.@table_name
              WHERE analysis_id IS NOT NULL
                {@analysis_ids != \"\"} ? { AND analysis_id IN (@analysis_ids)}
              ;",
      analysis_ids = analysisIds,
      table_name = dataSource$prefixTable("temporal_analysis_ref"),
      snakeCaseToCamelCase = TRUE,
      results_database_schema = dataSource$resultsDatabaseSchema
    ) %>%
    dplyr::tibble()

  temporalCovariateRefData <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      dbms = dataSource$dbms,
      sql = "SELECT *
             FROM @results_database_schema.@table_name
              WHERE covariate_id IS NOT NULL
                {@analysis_ids != \"\"} ? { AND analysis_id IN (@analysis_ids)};",
      snakeCaseToCamelCase = TRUE,
      analysis_ids = analysisIds,
      table_name = dataSource$prefixTable("temporal_covariate_ref"),
      results_database_schema = dataSource$resultsDatabaseSchema
    ) %>%
    dplyr::tibble()

  temporalCovariateValueData <- NULL
  if (temporalCovariateValue) {
    temporalCovariateValueData <-
      renderTranslateQuerySql(
        connection = dataSource$connection,
        dbms = dataSource$dbms,
        sql = "SELECT tcv.*
                FROM @results_database_schema.@table_name tcv
                INNER JOIN @results_database_schema.@ref_table_name ref ON ref.covariate_id = tcv.covariate_id
                WHERE ref.covariate_id IS NOT NULL
                {@analysis_ids != \"\"} ? { AND ref.analysis_id IN (@analysis_ids)}
                {@cohort_id != \"\"} ? { AND tcv.cohort_id IN (@cohort_id)}
                {@time_id != \"\"} ? { AND (time_id IN (@time_id) OR time_id IS NULL OR time_id = 0)}
                {@use_database_id} ? { AND database_id IN (@database_id)}
                {@filter_mean_threshold != \"\"} ? { AND tcv.mean > @filter_mean_threshold};",
        snakeCaseToCamelCase = TRUE,
        analysis_ids = analysisIds,
        time_id = temporalTimeRefData$timeId %>% unique(),
        use_database_id = !is.null(databaseIds),
        database_id = quoteLiterals(databaseIds),
        table_name = dataSource$prefixTable("temporal_covariate_value"),
        ref_table_name = dataSource$prefixTable("temporal_covariate_ref"),
        cohort_id = cohortIds,
        results_database_schema = dataSource$resultsDatabaseSchema,
        filter_mean_threshold = meanThreshold
      ) %>%
      dplyr::tibble() %>%
      tidyr::replace_na(replace = list(timeId = -1))
  }

  temporalCovariateValueDistData <- NULL
  if (temporalCovariateValueDist) {
    temporalCovariateValueDistData <-
      renderTranslateQuerySql(
        connection = dataSource$connection,
        dbms = dataSource$dbms,
        sql = "SELECT *
             FROM @results_database_schema.@table_name tcv
              WHERE covariate_id IS NOT NULL
                {@covariate_id != \"\"} ? { AND covariate_id IN (@covariate_id)}
                {@cohort_id != \"\"} ? { AND cohort_id IN (@cohort_id)}
                {@time_id != \"\"} ? { AND (time_id IN (@time_id) OR time_id IS NULL OR time_id = 0)}
                {@use_database_id} ? { AND database_id IN (@database_id)}
                {@filter_mean_threshold != \"\"} ? { AND tcv.mean > @filter_mean_threshold};",
        snakeCaseToCamelCase = TRUE,
        covariate_id = temporalCovariateRefData$covariateId %>% unique(),
        time_id = temporalTimeRefData$timeId %>% unique(),
        use_database_id = !is.null(databaseIds),
        database_id = quoteLiterals(databaseIds),
        cohort_id = cohortIds,
        table_name = dataSource$prefixTable("temporal_covariate_value_dist"),
        results_database_schema = dataSource$resultsDatabaseSchema,
        filter_mean_threshold = meanThreshold
      ) %>%
      dplyr::tibble() %>%
      tidyr::replace_na(replace = list(timeId = -1))
  }

  if (hasData(temporalCovariateValueData)) {
    temporalCovariateValueData <- temporalCovariateValueData %>%
      dplyr::left_join(temporalTimeRefData,
        by = "timeId"
      )
  }

  if (hasData(temporalCovariateValueDistData)) {
    temporalCovariateValueDistData <-
      temporalCovariateValueDistData %>%
      dplyr::left_join(temporalTimeRefData,
        by = "timeId"
      )
  }

  data <- list(
    temporalTimeRef = temporalTimeRefData,
    temporalAnalysisRef = temporalAnalysisRefData,
    temporalCovariateRef = temporalCovariateRefData,
    temporalCovariateValue = temporalCovariateValueData,
    temporalCovariateValueDist = temporalCovariateValueDistData
  )
  return(data)
}


getCharacterizationOutput <- function(dataSource,
                                      cohortIds,
                                      analysisIds = NULL,
                                      databaseIds,
                                      startDay = NULL,
                                      endDay = NULL,
                                      temporalCovariateValue = TRUE,
                                      temporalCovariateValueDist = TRUE,
                                      meanThreshold = 0.005) {
  temporalChoices <-
    getResultsTemporalTimeRef(dataSource = dataSource)

  covariateValue <- queryResultCovariateValue(
    dataSource = dataSource,
    cohortIds = cohortIds,
    analysisIds = analysisIds,
    databaseIds = databaseIds,
    startDay = startDay,
    endDay = endDay,
    temporalCovariateValue = temporalCovariateValue,
    temporalCovariateValueDist = temporalCovariateValueDist,
    meanThreshold = meanThreshold
  )

  postProcessCharacterizationValue <- function(data) {
    if ("timeId" %in% colnames(data$temporalCovariateValue)) {
      data$temporalCovariateValue$timeId <- NULL
    }
    resultCovariateValue <- data$temporalCovariateValue %>%
      dplyr::arrange(
        cohortId,
        databaseId,
        covariateId
      ) %>%
      dplyr::inner_join(data$temporalCovariateRef,
        by = "covariateId"
      ) %>%
      dplyr::inner_join(data$temporalAnalysisRef,
        by = "analysisId"
      ) %>%
      dplyr::left_join(
        temporalChoices %>%
          dplyr::select(
            startDay,
            endDay,
            timeId,
            temporalChoices
          ),
        by = c("startDay", "endDay")
      ) %>%
      dplyr::relocate(
        cohortId,
        databaseId,
        timeId,
        startDay,
        endDay,
        temporalChoices,
        analysisId,
        covariateId,
        covariateName,
        isBinary
      )

    if ("missingMeansZero" %in% colnames(resultCovariateValue)) {
      resultCovariateValue <- resultCovariateValue %>%
        dplyr::mutate(mean = dplyr::if_else(
          is.na(mean) &
            !is.na(missingMeansZero) &
            missingMeansZero == "Y",
          0,
          mean
        )) %>%
        dplyr::select(-missingMeansZero)
    }
    resultCovariateValue <- resultCovariateValue %>%
      dplyr::mutate(
        covariateName = stringr::str_replace_all(
          string = covariateName,
          pattern = "^.*: ",
          replacement = ""
        )
      ) %>%
      dplyr::mutate(covariateName = stringr::str_to_sentence(string = covariateName))

    if (!hasData(resultCovariateValue)) {
      return(NULL)
    }
    return(resultCovariateValue)
  }

  resultCovariateValue <- NULL
  if ("temporalCovariateValue" %in% names(covariateValue) &&
    hasData(covariateValue$temporalCovariateValue)) {
    resultCovariateValue <-
      postProcessCharacterizationValue(data = covariateValue)
  }

  cohortRelCharRes <-
    getCohortRelationshipCharacterizationResults(
      dataSource = dataSource,
      cohortIds = cohortIds,
      databaseIds = databaseIds
    )
  resultCohortValue <- NULL
  if ("temporalCovariateValue" %in% names(cohortRelCharRes) &&
    hasData(cohortRelCharRes$temporalCovariateValue)) {
    resultCohortValue <-
      postProcessCharacterizationValue(data = cohortRelCharRes)
  }

  resultCovariateValueDist <- NULL

  temporalCovariateValue <- NULL
  temporalCovariateValueDist <- NULL

  if (hasData(resultCovariateValue)) {
    temporalCovariateValue <- dplyr::bind_rows(
      temporalCovariateValue,
      resultCovariateValue
    )
  }

  if (hasData(resultCovariateValueDist)) {
    temporalCovariateValueDist <-
      dplyr::bind_rows(
        temporalCovariateValueDist,
        resultCovariateValueDist
      )
  }

  if (hasData(resultCohortValue)) {
    temporalCovariateValue <- dplyr::bind_rows(
      temporalCovariateValue,
      resultCohortValue
    )
  }

  return(
    list(
      covariateValue = temporalCovariateValue,
      covariateValueDist = temporalCovariateValueDist
    )
  )
}



#' Returns data from time_distribution table of Cohort Diagnostics results data model
#'
#' @description
#' Returns data from time_distribution table of Cohort Diagnostics results data model
#'
#' @template DataSource
#'
#' @template CohortIds
#'
#' @template DatabaseIds
#'
#' @return
#' Returns a data frame (tibble).
#'
#' @export
getTimeDistributionResult <- function(dataSource,
                                      cohortIds,
                                      databaseIds,
                                      databaseTable) {
  data <- queryResultCovariateValue(
    dataSource = dataSource,
    cohortIds = cohortIds,
    databaseIds = databaseIds,
    analysisIds = c(8, 9, 10),
    temporalCovariateValue = FALSE,
    temporalCovariateValueDist = TRUE
  )
  if (!hasData(data)) {
    return(NULL)
  }
  temporalCovariateValueDist <- data$temporalCovariateValueDist
  if (!hasData(temporalCovariateValueDist)) {
    return(NULL)
  }
  data <- temporalCovariateValueDist %>%
    dplyr::inner_join(data$temporalCovariateRef,
      by = "covariateId"
    ) %>%
    dplyr::inner_join(data$temporalAnalysisRef,
      by = "analysisId"
    ) %>%
    dplyr::inner_join(databaseTable,
      by = "databaseId"
    ) %>%
    dplyr::rename(
      "timeMetric" = covariateName,
      "averageValue" = mean,
      "standardDeviation" = sd
    ) %>%
    dplyr::select(
      "cohortId",
      "databaseId",
      "databaseName",
      "timeMetric",
      "averageValue",
      "standardDeviation",
      "minValue",
      "p10Value",
      "p25Value",
      "medianValue",
      "p75Value",
      "p90Value",
      "maxValue"
    )
  return(data)
}


#' Returns matrix of relationship between target and comparator cohortIds
#'
#' @description
#' Given a list of target and comparator cohortIds gets temporal relationship.
#'
#' @template DataSource
#'
#' @template CohortIds
#'
#' @template ComparatorCohortIds
#'
#' @template DatabaseIds
#'
#' @param    relationshipDays A vector of integer representing days comparator cohort
#'           start to target cohort start
#'
#' @param    relationshipType What type of relationship do you want to retrieve. The
#'           available options are 'start', 'end', 'overlap'.
#'
#' @return
#' Returns a data frame (tibble)
#'
#' @export
getCohortTemporalRelationshipMatrix <- function(dataSource,
                                                databaseIds = NULL,
                                                cohortIds = NULL,
                                                comparatorCohortIds = NULL,
                                                relationshipType = "start") {
  if (relationshipType == "start") {
    variableName <- "sub_cs_window_t"
  } else if (relationshipType == "end") {
    variableName <- "sub_ce_window_t"
  } else if (relationshipType == "overlap") {
    variableName <- "sub_c_within_t"
  } else {
    stop("Unrecognized relationshipType. Available options are 'start', 'end','overlap'")
  }

  data <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      dbms = dataSource$dbms,
      sql = "SELECT DISTINCT database_id,
                    cohort_id,
                    comparator_cohort_id,
                    start_day,
                    end_day,
                    sub_cs_window_t
             FROM @results_database_schema.@table_name
             WHERE cohort_id IN (@cohort_id) AND
             database_id IN (@database_id)
              {@start_day != \"\"} ? { AND start_day IN (@start_day)}
              {@end_day != \"\"} ? { AND end_day IN (@end_day)};",
      snakeCaseToCamelCase = TRUE,
      results_database_schema = dataSource$resultsDatabaseSchema,
      cohort_id = cohortIds,
      database_id = quoteLiterals(databaseIds),
      table_name = dataSource$prefixTable("cohort_relationships"),
      start_day = startDay,
      end_day = endDay
    ) %>%
    dplyr::tibble()
  if (any(
    (is.null(data)),
    nrow(data) == 0
  )) {
    return(NULL)
  }

  data <- data %>%
    dplyr::select(
      databaseId,
      cohortId,
      comparatorCohortId,
      startDay,
      subCsWindowT
    ) %>%
    dplyr::mutate(
      day = dplyr::case_when(
        startDay < 0 ~ paste0("dm", abs(startDay)),
        startDay > 0 ~ paste0("dp", abs(startDay)),
        startDay == 0 ~ paste0("d", abs(startDay))
      )
    ) %>%
    dplyr::arrange(
      databaseId,
      cohortId,
      comparatorCohortId,
      startDay
    ) %>%
    dplyr::distinct() %>%
    tidyr::pivot_wider(
      id_cols = c("databaseId", "cohortId", "comparatorCohortId"),
      names_from = "day",
      values_from = "subCsWindowT"
    )

  return(data)
}



#' Returns data for use in cohort co-occurrence matrix
#'
#' @description
#' Returns a a data frame (tibble) that shows the percent (optionally number) of subjects
#' in target cohort that are also in comparator cohort at certain days relative to
#' first start date of a subject in target cohort.
#'
#' @template DataSource
#'
#' @template TargetCohortIds
#'
#' @template ComparatorCohortIds
#'
#' @template DatabaseIds
#'
#' @template StartDays
#'
#' @template endDays
#'
#' @param showPercent Return percent instead of raw numbers
#'
#' @return
#' Returns a data frame (tibble). Note - the computation is in relation
#' to first start of target cohort only.
#'
#' @export
getResultsCohortCoOccurrenceMatrix <- function(dataSource,
                                               targetCohortIds = NULL,
                                               comparatorCohortIds = NULL,
                                               databaseIds = NULL,
                                               startDays = NULL,
                                               endDays = NULL,
                                               showPercent = TRUE) {
  cohortCount <- getResultsCohortCount(
    dataSource = dataSource,
    cohortIds = c(targetCohortIds, comparatorCohortIds) %>% unique(),
    databaseIds = databaseIds
  )
  if (is.null(data$cohortCount)) {
    return(NULL)
  }

  cohortRelationship <- getResultsCohortRelationships(
    dataSource = dataSource,
    cohortIds = targetCohortIds,
    comparatorCohortIds = comparatorCohortIds,
    databaseIds = databaseIds,
    startDays = startDays,
    endDays = endDays
  )
  if (is.null(cohortRelationship)) {
    return(NULL)
  }


  cohortRelationship <- cohortRelationship %>%
    dplyr::mutate(records = 0) %>%
    dplyr::rename(
      "targetCohortId" = cohortId,
      "comparatorCohortId" = comparatorCohortId,
      "bothSubjects" = subjects,
      "bothRecords" = records
    ) %>%
    dplyr::select(
      databaseId,
      targetCohortId,
      comparatorCohortId,
      startDay,
      endDay,
      # overlap - comparator period overlaps target period (offset)
      bothSubjects,
      bothRecords,
      # comparator start on Target Start
      recCsOnTs,
      subCsOnTs,
      subCsWindowT
    )

  coOccurrenceMatrix <- cohortRelationship %>%
    dplyr::filter(startDay == endDay) %>%
    dplyr::mutate(dayName = dplyr::case_when(
      startDay < 0 ~ paste0("dayNeg", abs(startDay)),
      TRUE ~ paste0("dayPos", abs(startDay))
    )) %>%
    dplyr::select(
      databaseId,
      targetCohortId,
      comparatorCohortId,
      dayName,
      bothSubjects,
      subCsOnTs,
      subCsWindowT
    )

  matrixOverlap <- coOccurrenceMatrix %>%
    dplyr::filter(!is.na(bothSubjects)) %>%
    dplyr::select(
      databaseId,
      targetCohortId,
      comparatorCohortId,
      dayName,
      bothSubjects
    ) %>%
    tidyr::pivot_wider(
      id_cols = c(
        databaseId,
        targetCohortId,
        comparatorCohortId
      ),
      names_from = dayName,
      values_from = bothSubjects
    ) %>%
    dplyr::mutate(type = "overlap")

  matrixStart <- coOccurrenceMatrix %>%
    dplyr::filter(!is.na(subCsOnTs)) %>%
    dplyr::select(
      databaseId,
      targetCohortId,
      comparatorCohortId,
      dayName,
      subCsOnTs
    ) %>%
    tidyr::pivot_wider(
      id_cols = c(
        databaseId,
        targetCohortId,
        comparatorCohortId
      ),
      names_from = dayName,
      values_from = subCsOnTs
    ) %>%
    dplyr::mutate(type = "start")

  matrixStartWindows <- coOccurrenceMatrix %>%
    dplyr::filter(!is.na(subCsWindowT)) %>%
    dplyr::select(
      databaseId,
      targetCohortId,
      comparatorCohortId,
      dayName,
      subCsWindowT
    ) %>%
    tidyr::pivot_wider(
      id_cols = c(
        databaseId,
        targetCohortId,
        comparatorCohortId
      ),
      names_from = dayName,
      values_from = subCsWindowT
    ) %>%
    dplyr::mutate(type = "startWindow")

  matrix <- dplyr::bind_rows(
    matrixOverlap,
    matrixStart,
    matrixStartWindows
  )
  if (showPercent) {
    matrix <- matrix %>%
      dplyr::inner_join(
        cohortCount %>%
          dplyr::select(
            databaseId,
            cohortId,
            cohortSubjects
          ) %>%
          dplyr::rename("targetCohortId" = cohortId),
        by = c("targetCohortId", "databaseId")
      ) %>%
      dplyr::mutate(dplyr::across(.cols = dplyr::starts_with("day")) / cohortSubjects)
  }
  return(matrix)
}




#' Returns data for use in cohort_overlap
#'
#' @description
#' Returns data for use in cohort_overlap
#'
#' @template DataSource
#'
#' @param targetCohortIds A vector of cohort ids representing target cohorts
#'
#' @param comparatorCohortIds A vector of cohort ids representing comparator cohorts
#'
#' @template DatabaseIds
#'
#' @return
#' Returns data for use in cohort_overlap
#'
#' @export
getResultsCohortOverlap <- function(dataSource,
                                    targetCohortIds = NULL,
                                    comparatorCohortIds = NULL,
                                    databaseIds = NULL) {
  cohortIds <- c(targetCohortIds, comparatorCohortIds) %>% unique()
  cohortCounts <-
    getResultsCohortCounts(
      dataSource = dataSource,
      cohortIds = cohortIds,
      databaseIds = databaseIds
    )

  if (!hasData(cohortCounts)) {
    return(NULL)
  }

  cohortRelationship <-
    getResultsCohortRelationships(
      dataSource = dataSource,
      cohortIds = cohortIds,
      comparatorCohortIds = comparatorCohortIds,
      databaseIds = databaseIds,
      startDays = c(-9999, 0),
      endDays = c(9999, 0)
    )

  # Fix relationship data so 0 overlap displays
  allCombinations <- dplyr::tibble(databaseId = databaseIds) %>%
        tidyr::crossing(dplyr::tibble(cohortId = cohortIds)) %>%
        tidyr::crossing(dplyr::tibble(comparatorCohortId = comparatorCohortIds)) %>%
        dplyr::filter(comparatorCohortId != cohortId) %>%
        tidyr::crossing(dplyr::tibble(startDay = c(-9999, 0),
                                      endDay = c(9999, 0)))

  cohortRelationship <- allCombinations %>%
    dplyr::left_join(cohortRelationship,
                     by = c("databaseId", "cohortId", "comparatorCohortId", "startDay", "endDay")) %>%
    dplyr::mutate(dplyr::across(.cols = where(is.numeric), ~tidyr::replace_na(., 0)))

  fullOffSet <- cohortRelationship %>%
    dplyr::filter(startDay == -9999) %>%
    dplyr::filter(endDay == 9999) %>%
    dplyr::filter(cohortId %in% c(targetCohortIds)) %>%
    dplyr::filter(comparatorCohortId %in% c(comparatorCohortIds)) %>%
    dplyr::select(
      databaseId,
      cohortId,
      comparatorCohortId,
      subjects
    ) %>%
    dplyr::inner_join(
      cohortCounts %>%
        dplyr::select(-cohortEntries) %>%
        dplyr::rename(targetCohortSubjects = cohortSubjects),
      by = c("databaseId", "cohortId")
    ) %>%
    dplyr::mutate(tOnlySubjects = targetCohortSubjects - subjects) %>%
    dplyr::inner_join(
      cohortCounts %>%
        dplyr::select(-cohortEntries) %>%
        dplyr::rename(
          comparatorCohortSubjects = cohortSubjects,
          comparatorCohortId = cohortId
        ),
      by = c("databaseId", "comparatorCohortId")
    ) %>%
    dplyr::mutate(cOnlySubjects = comparatorCohortSubjects - subjects) %>%
    dplyr::mutate(eitherSubjects = cOnlySubjects + tOnlySubjects + subjects) %>%
    dplyr::rename(
      targetCohortId = cohortId,
      bothSubjects = subjects
    ) %>%
    dplyr::select(
      databaseId,
      targetCohortId,
      comparatorCohortId,
      bothSubjects,
      tOnlySubjects,
      cOnlySubjects,
      eitherSubjects
    )


  noOffset <- cohortRelationship %>%
    dplyr::filter(comparatorCohortId %in% comparatorCohortIds) %>%
    dplyr::filter(cohortId %in% targetCohortIds) %>%
    dplyr::filter(startDay == 0) %>%
    dplyr::filter(endDay == 0) %>%
    dplyr::select(
      databaseId,
      cohortId,
      comparatorCohortId,
      subCsBeforeTs,
      subCWithinT,
      subCsAfterTs,
      subCsAfterTe,
      subCsBeforeTs,
      subCsBeforeTe,
      subCsOnTs,
      subCsOnTe
    ) %>%
    dplyr::rename(
      cBeforeTSubjects = subCsBeforeTs,
      targetCohortId = cohortId,
      cInTSubjects = subCWithinT,
      cStartAfterTStart = subCsAfterTs,
      cStartAfterTEnd = subCsAfterTe,
      cStartBeforeTStart = subCsBeforeTs,
      cStartBeforeTEnd = subCsBeforeTe,
      cStartOnTStart = subCsOnTs,
      cStartOnTEnd = subCsOnTe
    )

  result <- fullOffSet %>%
    dplyr::left_join(noOffset,
      by = c("databaseId", "targetCohortId", "comparatorCohortId")
    ) %>%
    dplyr::filter(targetCohortId != comparatorCohortId) %>%
    dplyr::select(
      databaseId,
      # cohortId,
      comparatorCohortId,
      eitherSubjects,
      tOnlySubjects,
      cOnlySubjects,
      bothSubjects,
      # cBeforeTSubjects,
      targetCohortId,
      cInTSubjects,
      cStartAfterTStart,
      cStartAfterTEnd,
      cStartBeforeTStart,
      cStartBeforeTEnd,
      cStartOnTStart,
      cStartOnTEnd,
    )

  databaseNames <- cohortCounts %>% dplyr::distinct(databaseId, databaseName)
  result <- result %>% dplyr::inner_join(databaseNames, by = "databaseId")

  return(result)
}


#' Returns data from cohort_relationships table of Cohort Diagnostics results data model
#'
#' @description
#' Returns data from cohort_relationships table of Cohort Diagnostics results data model
#'
#' @template DataSource
#'
#' @template CohortIds
#'
#' @template ComparatorCohortIds
#'
#' @template DatabaseIds
#'
#' @param startDays A vector of days in relation to cohort_start_date of target
#'
#' @param endDays A vector of days in relation to cohort_end_date of target
#'
#' @return
#' Returns a data frame (tibble) with results that conform to cohort_relationships
#' table in Cohort Diagnostics results data model.
#'
#' @export
getResultsCohortRelationships <- function(dataSource,
                                          cohortIds = NULL,
                                          comparatorCohortIds = NULL,
                                          databaseIds = NULL,
                                          startDays = NULL,
                                          endDays = NULL) {
  data <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      dbms = dataSource$dbms,
      sql = "SELECT cr.*, db.database_name
             FROM @results_database_schema.@table_name cr
             INNER JOIN @results_database_schema.@database_table db ON db.database_id = cr.database_id
             WHERE cr.cohort_id IN (@cohort_id)
             AND cr.database_id IN (@database_id)
              {@comparator_cohort_id != \"\"} ? { AND cr.comparator_cohort_id IN (@comparator_cohort_id)}
              {@start_day != \"\"} ? { AND cr.start_day IN (@start_day)}
              {@end_day != \"\"} ? { AND cr.end_day IN (@end_day)};",
      snakeCaseToCamelCase = TRUE,
      results_database_schema = dataSource$resultsDatabaseSchema,
      database_id = quoteLiterals(databaseIds),
      table_name = dataSource$prefixTable("cohort_relationships"),
      database_table = dataSource$databaseTableName,
      cohort_id = cohortIds,
      comparator_cohort_id = comparatorCohortIds,
      start_day = startDays,
      end_day = endDays
    ) %>%
    dplyr::tibble()

  return(data)
}


#' Returns cohort as feature characterization
#'
#' @description
#' Returns a list object with covariateValue,
#' covariateRef, analysisRef output of cohort as features.
#'
#' @template DataSource
#'
#' @template CohortIds
#'
#' @template DatabaseIds
#'
#' @return
#' Returns a list object with covariateValue,
#' covariateRef, analysisRef output of cohort as features. To avoid clash
#' with covaraiteId and conceptId returned from Feature Extraction
#' the output is a negative integer.
#'
#' @export
getCohortRelationshipCharacterizationResults <-
  function(dataSource = .GlobalEnv,
           cohortIds = NULL,
           databaseIds = NULL) {
    cohortCounts <-
      getResultsCohortCounts(
        dataSource = dataSource,
        cohortIds = cohortIds,
        databaseIds = databaseIds
      )
    cohort <- getResultsCohort(dataSource = dataSource)

    cohortRelationships <-
      getResultsCohortRelationships(
        dataSource = dataSource,
        cohortIds = cohortIds,
        databaseIds = databaseIds
      )

    # cannot do records because comparator cohorts may have sumValue > target cohort (which is first occurrence only)
    # subjects overlap
    subjectsOverlap <- cohortRelationships %>%
      dplyr::inner_join(cohortCounts,
        by = c("cohortId", "databaseId")
      ) %>%
      dplyr::mutate(sumValue = subCeWindowT + subCsWindowT - subCWithinT) %>%
      dplyr::mutate(mean = sumValue / cohortSubjects) %>%
      dplyr::select(
        cohortId,
        comparatorCohortId,
        databaseId,
        startDay,
        endDay,
        mean,
        sumValue
      ) %>%
      dplyr::mutate(analysisId = -301)

    # subjects start
    subjectsStart <- cohortRelationships %>%
      dplyr::inner_join(cohortCounts,
        by = c("cohortId", "databaseId")
      ) %>%
      dplyr::mutate(sumValue = subCsWindowT) %>%
      dplyr::mutate(mean = sumValue / cohortSubjects) %>%
      dplyr::select(
        cohortId,
        comparatorCohortId,
        databaseId,
        startDay,
        endDay,
        mean,
        sumValue
      ) %>%
      dplyr::mutate(analysisId = -201)

    data <- dplyr::bind_rows(
      subjectsOverlap,
      subjectsStart
    ) %>%
      dplyr::filter(comparatorCohortId > 0) %>%
      dplyr::mutate(covariateId = (comparatorCohortId * -1000) + analysisId)

    # suppressing warning because of - negative causing NaN values
    data <- suppressWarnings(expr = {
      data %>%
        dplyr::mutate(sd = sqrt(mean * (1 - mean)))
    }, classes = "warning")

    temporalTimeRefFull <-
      getResultsTemporalTimeRef(dataSource = dataSource)

    temporalTimeRef <- data %>%
      dplyr::select(
        startDay,
        endDay
      ) %>%
      dplyr::distinct() %>%
      dplyr::inner_join(temporalTimeRefFull,
        by = c(
          "startDay",
          "endDay"
        )
      )

    analysisRef <-
      dplyr::tibble(
        analysisId = c(-201, -301),
        analysisName = c("CohortEraStart", "CohortEraOverlap"),
        domainId = "Cohort",
        isBinary = "Y",
        missingMeansZero = "Y"
      ) %>%
      dplyr::inner_join(data %>%
        dplyr::select(analysisId) %>%
        dplyr::distinct(),
      by = c("analysisId")
      )
    covariateRef <- tidyr::crossing(
      cohort,
      analysisRef %>%
        dplyr::select(
          analysisId,
          analysisName
        )
    ) %>%
      dplyr::mutate(covariateId = (cohortId * -1000) + analysisId) %>%
      dplyr::inner_join(data %>% dplyr::select(covariateId) %>% dplyr::distinct(),
        by = "covariateId"
      ) %>%
      dplyr::mutate(covariateName = paste0(
        analysisName,
        ": (",
        cohortId,
        ") ",
        cohortName
      )) %>%
      dplyr::mutate(conceptId = cohortId * -1) %>%
      dplyr::arrange(covariateId) %>%
      dplyr::select(
        analysisId,
        conceptId,
        covariateId,
        covariateName
      )
    concept <- cohort %>%
      dplyr::filter(cohortId %in% c(data$comparatorCohortId %>% unique())) %>%
      dplyr::mutate(
        conceptId = cohortId * -1,
        conceptName = cohortName,
        domainId = "Cohort",
        vocabularyId = "Cohort",
        conceptClassId = "Cohort",
        standardConcept = "S",
        conceptCode = as.character(cohortId),
        validStartDate = as.Date("2002-01-31"),
        validEndDate = as.Date("2099-12-31"),
        invalidReason = as.character(NA)
      ) %>%
      dplyr::select(
        conceptId,
        conceptName,
        domainId,
        vocabularyId,
        conceptClassId,
        standardConcept,
        conceptCode,
        validStartDate,
        validEndDate,
        invalidReason
      ) %>%
      dplyr::arrange(conceptId)

    covariateValue <- data %>%
      dplyr::select(
        cohortId,
        covariateId,
        databaseId,
        startDay,
        endDay,
        mean,
        sd,
        sumValue
      )

    data <- list(
      temporalCovariateRef = covariateRef,
      temporalCovariateValue = covariateValue,
      temporalCovariateValueDist = NULL,
      temporalAnalysisRef = analysisRef,
      concept = concept
    )
    return(data)
  }


# Cohort ----
#' Returns data from cohort table of Cohort Diagnostics results data model
#'
#' @description
#' Returns data from cohort table of Cohort Diagnostics results data model
#'
#' @template DataSource
#'
#' @template CohortIds
#'
#' @return
#' Returns a data frame (tibble)
#'
#' @export
getResultsCohort <- function(dataSource, cohortIds = NULL) {
  data <- renderTranslateQuerySql(
    connection = dataSource$connection,
    results_database_schema = dataSource$resultsDatabaseSchema,
    dbms = dataSource$dbms,
    sql = "SELECT * FROM @results_database_schema.@table_name
                                          {@cohort_id != \"\"} ? { WHERE cohort_id IN (@cohort_id)};",
    cohort_id = cohortIds,
    table_name = dataSource$cohortTableName,
    snakeCaseToCamelCase = TRUE
  )
  return(data)
}


# not exported
getResultsCovariateRef <- function(dataSource,
                                   covariateIds = NULL) {
  sql <- "SELECT *
            FROM @results_database_schema.@table_name
            {@covariate_ids == ''} ? { WHERE covariate_id IN (@covariate_ids)}
            ;"
  data <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      sql = sql,
      results_database_schema = dataSource$resultsDatabaseSchema,
      covariate_id = covariateIds,
      table_name = dataSource$prefixTable("covariate_ref"),
      snakeCaseToCamelCase = TRUE
    )

  if (!hasData(data)) {
    return(NULL)
  }
  return(data)
}

# not exported
getResultsTemporalCovariateRef <- function(dataSource,
                                           covariateIds = NULL) {
  sql <- "SELECT *
            FROM @results_database_schema.@table_name
            {@covariate_ids == ''} ? { WHERE covariate_id IN (@covariate_ids)};"
  data <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      sql = sql,
      results_database_schema = dataSource$resultsDatabaseSchema,
      table_name = dataSource$prefixTable("temporal_time_ref"),
      covariate_id = covariateIds,
      snakeCaseToCamelCase = TRUE
    )

  if (!hasData(data)) {
    return(NULL)
  }
  return(data)
}

# not exported
getResultsTemporalTimeRef <- function(dataSource) {
  sql <- "SELECT *
            FROM @results_database_schema.@table_name;"
  temporalTimeRef <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      dbms = dataSource$dbms,
      sql = sql,
      results_database_schema = dataSource$resultsDatabaseSchema,
      table_name = dataSource$prefixTable("temporal_time_ref"),
      snakeCaseToCamelCase = TRUE
    )

  if (nrow(temporalTimeRef) == 0) {
    return(NULL)
  }

  temporalChoices <- temporalTimeRef %>%
    dplyr::mutate(temporalChoices = paste0("T (", startDay, "d to ", endDay, "d)")) %>%
    dplyr::arrange(startDay, endDay) %>%
    dplyr::select(
      timeId,
      startDay,
      endDay,
      temporalChoices
    ) %>%
    dplyr::mutate(primaryTimeId = dplyr::if_else(
      condition = (
        (startDay == -365 & endDay == -31) |
          (startDay == -30 & endDay == -1) |
          (startDay == 0 & endDay == 0) |
          (startDay == 1 & endDay == 30) |
          (startDay == 31 & endDay == 365) |
          (startDay == -365 & endDay == 0) |
          (startDay == -30 & endDay == 0)
      ),
      true = 1,
      false = 0
    )) %>%
    dplyr::mutate(isTemporal = dplyr::if_else(
      condition = (
        (endDay == 0 & startDay == -30) |
          (endDay == 0 & startDay == -180) |
          (endDay == 0 & startDay == -365) |
          (endDay == 0 & startDay == -9999)
      ),
      true = 0,
      false = 1
    )) %>%
    dplyr::arrange(startDay, timeId, endDay)

  temporalChoices <- dplyr::bind_rows(
    temporalChoices %>% dplyr::slice(0),
    dplyr::tibble(
      timeId = -1,
      temporalChoices = "Time invariant",
      primaryTimeId = 1,
      isTemporal = 0
    ),
    temporalChoices
  ) %>%
    dplyr::mutate(sequence = dplyr::row_number())

  return(temporalChoices)
}


# not exported
getResultsAnalysisRef <- function(dataSource) {
  dataTableName <- "analysisRef"
  sql <- "SELECT *
            FROM @results_database_schema.@table_name;"
  data <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      dbms = dataSource$dbms,
      sql = sql,
      results_database_schema = dataSource$resultsDatabaseSchema,
      table_name = dataSource$prefixTable("analysis_ref"),
      snakeCaseToCamelCase = TRUE
    )
  if (nrow(data) == 0) {
    return(NULL)
  }
  return(data)
}


# not exported
getResultsTemporalAnalysisRef <- function(dataSource) {
  sql <- "SELECT *
            FROM @results_database_schema.@table_name;"
  data <-
    renderTranslateQuerySql(
      connection = dataSource$connection,
      dbms = dataSource$dbms,
      sql = sql,
      results_database_schema = dataSource$resultsDatabaseSchema,
      table_name = dataSource$prefixTable("temporal_analysis_ref"),
      snakeCaseToCamelCase = TRUE
    )
  if (nrow(data) == 0) {
    return(NULL)
  }
  return(data)
}
