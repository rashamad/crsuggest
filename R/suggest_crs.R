#' Suggest coordinate systems for an input spatial dataset
#'
#' @param input A spatial dataset of class \code{"sf"}, \code{"Spatial*"}, or
#'              \code{"RasterLayer"}.
#' @param type The output CRS type; defaults to \code{"projected"}.
#' @param limit How many results to return; defaults to \code{10}.
#' @param gcs (optional) The EPSG code for the corresponding geographic coordinate system of the results (e.g. \code{4326} for WGS 1984).
#' @param units (optional) The measurement units of the coordinate systems in the returned results.  Can be one of \code{"m"}, \code{"ft"}, or \code{"ft-us"}.
#'
#' @return A data frame with information about coordinate reference systems that could be suitably used for CRS transformation.
#' @export
suggest_crs <- function(input, type = "projected",
                        limit = 10, gcs = NULL,
                        units = NULL) {

  # If the input is a raster layer, convert to a polygon at the
  # extent of that layer
  if ("RasterLayer" %in% class(input)) {
    input <- input %>%
      st_bbox() %>%
      st_as_sfc()
  }

  # If object is from the sp package, convert to sf
  if (any(grepl("Spatial", class(input)))) {
    input <- st_as_sf(input)
  }

  # If it is a simple feature collection, make into sf
  if ("sfc" %in% class(input)) {
    input <- st_sf(input)
  }

  # Filter the CRS object for the selected type, GCS, and units if requested
  crs_type <- dplyr::filter(crsuggest::crs_sf, crs_type == type)

  if (!is.null(gcs)) {
    gcs <- as.character(gcs)
    crs_type <- dplyr::filter(crs_type, crs_gcs == gcs)
  }

  if (!is.null(units)) {
    if (!units %in% c("ft", "m", "us-ft")) {
      stop("Units must be one of 'm', 'ft', or 'us-ft'")
    }

    crs_type <- dplyr::filter(crs_type, crs_units == units)
  }

  # Transform the input SF object to 32663 for overlay
  sf_proj <- st_transform(input, st_crs(crs_type))

  # If geometry type is POINT or MULTIPOINT, union then find the convex hull
  # If geometry type is LINESTRING or MULTILINESTRING, cast as POINT then do the above
  # If geometry type is POLYGON or MULTIPOLYGON, union
  geom_type <- unique(st_geometry_type(sf_proj))

  # Consider at later date how to handle mixed geometries
  # Also consider whether to use concave hulls instead to avoid edge cases

  if (geom_type %in% c("POINT", "MULTIPOINT")) {
    # If it is a single point, buffer it
    if (nrow(sf_proj) == 1) {
      sf_proj <- st_buffer(sf_proj, 1000)
    }

    sf_poly <- sf_proj %>%
      st_union() %>%
      st_convex_hull()
  } else if (geom_type %in% c("LINESTRING", "MULTILINESTRING")) {
    sf_poly <- sf_proj %>%
      st_cast("MULTIPOINT") %>%
      st_union() %>%
      st_convex_hull()
  } else if (geom_type %in% c("POLYGON", "MULTIPOLYGON")) {
    sf_poly <- sf_proj %>%
      st_union()
    }


  # Subset the area extent polygons further to those that intersect with our area of interest
  # To (try to) avoid edge cases, compute a "reverse buffer" of the geometry
  # by which we remove the area within 500m of the polygon's boundary
  reverse_buf <- st_buffer(sf_poly, -500)

  crs_sub <- crs_type[reverse_buf, ]

  # If this doesn't yield anything, we need to re-run and keep trying until
  # we get a valid result
  if (nrow(crs_sub) == 0) {
    rows <- nrow(crs_sub)
    bufdist <- -250
    while (rows == 0) {
      new_buf <- st_buffer(sf_poly, bufdist)
      crs_sub <- crs_type[new_buf, ]
      rows <- nrow(crs_sub)
      bufdist <- bufdist / 2
    }

  }

  # Simplify the polygon if it is too large (>500 vertices)
  # Keep simplifying until the count is sufficiently reduced
  # (as general shape will be OK here)
  vertex_count <- mapview::npts(sf_poly)

  if (vertex_count > 500) {
    tol <- 5000
    vc <- vertex_count
    while (vc > 500) {
      sf_poly <- st_simplify(sf_poly, dTolerance = tol)
      vc <- mapview::npts(sf_poly)
      tol <- tol * 2
    }
  }

  # Calculate the Hausdorff distance between the area of interest and the polygons,
  # then sort in ascending order of distance and return the top requested CRSs
  crs_output <- crs_sub %>%
    dplyr::mutate(hausdist = as.numeric(
      st_distance(
        sf_poly, ., which = "Hausdorff"
      )
    )) %>%
    st_drop_geometry() %>%
    dplyr::arrange(hausdist) %>%
    dplyr::filter(dplyr::row_number() <= limit) %>%
    dplyr::select(-hausdist)

  return(crs_output)

}


#' Return the CRS code for a "best-fit" projected coordinate reference system
#'
#' Return the EPSG code or proj4string syntax for the top-ranking projected coordinate reference system returned by \code{suggest_crs()}.  This function should be used with caution and is recommended for interactive work rather than in production data pipelines.
#'
#' @param input An input spatial dataset of class \code{"sf"}, \code{"Spatial*"}, or \code{"RasterLayer"}.
#' @param units (optional) The measurement units used by the returned coordinate reference system.
#' @param inherit_gcs if \code{TRUE} (the default), the function will return a CRS suggestion that uses the geographic coordinate system of the input layer.  Otherwise, the output may use a different geographic coordinate system from the input.
#' @param output one of \code{"epsg"}, for the EPSG code, or \code{"proj4string"}, for the proj4string syntax.
#'
#' @return the EPSG code or proj4string for the output coordinate reference system
#' @export
suggest_top_crs <- function(input, units = NULL, inherit_gcs = TRUE,
                            output = "epsg") {


  if (inherit_gcs) {
    # First, determine if the dataset is in a GCS already
    existing_epsg <- st_crs(input)$epsg

    gcs_codes <- crsuggest::crs_sf %>%
      dplyr::filter(crs_type == "geographic 2D") %>%
      dplyr::pull(crs_code) %>%
      unique()

    is_gcs <- existing_epsg %in% gcs_codes

    if (is_gcs) {
      suggestion <- crsuggest::suggest_crs(input,
                                           limit = 1,
                                           gcs = existing_epsg,
                                           units = units)


    } else {
      current_gcs <- crsuggest::crs_sf %>%
        dplyr::filter(crs_code == existing_epsg) %>%
        pull(crs_gcs)

      suggestion <- crsuggest::suggest_crs(input,
                                           limit = 1,
                                           gcs = current_gcs,
                                           units = units)

    }
  } else {
    suggestion <- crsuggest::suggest_crs(input,
                                         limit = 1,
                                         units = units)

  }

  if (output == "epsg") {
    toreturn <- suggestion$crs_code %>% as.integer()
    infodf <- crsuggest::crs_sf %>%
      dplyr::filter(crs_code == toreturn)
  } else if (output == "proj4string") {
    toreturn <- suggestion$proj4string
    infodf <- crsuggest::crs_sf %>%
      dplyr::filter(crs_proj4 == toreturn)
  } else {
    stop("`output` must be one of 'epsg' or 'proj4string'.",
         call. = FALSE)
  }

  message(sprintf("Using the projected CRS %s which uses '%s' for measurement units. Please visit https://spatialreference.org/ref/epsg/%s/ for more information about this CRS.",
                  infodf$crs_name, infodf$crs_units, infodf$crs_code))

  return(toreturn)

}
