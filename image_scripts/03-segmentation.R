#' This script extracts segment using one channel (default input should be the green channel)
#'
#' To use this Rscript, in bash environment:
#' Rscript 03-segmentation.R list_images.csv
#'
#' For example:
#' Rscript 03-segmentation.R mapping_files/00-list_images-B2-green.csv

library(tidyverse)
library(EBImage)

list_images <- read_csv(commandArgs(trailingOnly = T)[1], show_col_types = F)
paste_folder_name <- function (image_type = "channel", channel = "green") {
    paste0(list_images[i,paste0("folder_", image_type)], channel, "/")
}
compute_feature <- function (image_object, image_intensity) {
    computeFeatures(
        image_object, image_intensity,
        methods.noref = c("computeFeatures.shape"),
        methods.ref = c("computeFeatures.basic", "computeFeatures.moment"),
        basic.quantiles = c(0.05, 0.5)) %>%
        as_tibble(rownames = "ObjectID") %>%
        # Remove duplicatedly calculated properties
        select(ObjectID, starts_with("x.0"), starts_with("x.Ba")) %>%
        # Remove the redundant prefix
        rename_with(function(x) str_replace(x,"x.0.", ""), starts_with("x.0")) %>%
        rename_with(function(x) str_replace(x,"x.Ba.", ""), starts_with("x.Ba")) %>%
        select(ObjectID, starts_with("b."), starts_with("s."), starts_with("m."))
}
detect_nonround_object <- function (image_object, image_intensity = NULL, after_watershed = F) {
    # Remove too large or too small objects before watershed to reduce computational load
    if (!after_watershed) {
        # Check if the are away from the image border (use 100 pixel)
        oc <- ocontour(image_object)
        inside <- sapply(oc, function (x) {
            if (all(x[,1] > 100 & x[,1] < (nrow(image_rolled)-100) & x[,2] > 100 & x[,2] < (ncol(image_rolled)-100))) {
                return (T)
            } else return(F)
        })
        object_feature <- computeFeatures.shape(image_object) %>% as_tibble(rownames = "ObjectID")
        object_shape_round <- object_feature %>%
            mutate(inside = inside) %>%
            # Area
            filter(s.area > 300 & s.area < 20000) %>%
            # Contour located away from the edges
            filter(inside)

    }

    # Filter for circularity only after watershed segmentation
    if (after_watershed) {
        object_feature <- compute_feature(image_object, image_intensity)

        # Remove segmented objects based on shape
        object_shape_round <- object_feature %>%
            # Area. Remove small objects after segementation
            filter(s.area > 300 & s.area < 20000) %>%
            # Circularity = 1 means a perfect circle and goes down to 0 for non-circular shapes
            mutate(Circularity = 4 * pi * s.area / s.perimeter^2) %>%
            filter(Circularity > 0.7) %>%
            # Remove tape and label that has really large variation in radius
            filter(s.radius.sd/s.radius.mean < 0.2)

    }

    # Arrange by area size
    object_shape_round <- object_shape_round %>% arrange(desc(s.area))
    object_ID_nonround <- object_feature$ObjectID[!(object_feature$ObjectID %in% object_shape_round$ObjectID)]
    return(object_ID_nonround)
}

for (i in 1:nrow(list_images)) {
    image_name <- list_images$image_name[i]
    color_channel <- list_images$color_channel[i]
    cat("\n", color_channel)

    # Rolled image
    image_rolled <- readImage(paste0(paste_folder_name("rolled", color_channel), image_name, ".tiff"))

    # 3. Thresholding
    #' thresh() applies a sliding window to calculate the local threshold
    #' opening() brushes the image to remove very tiny objects
    image_threshold <- thresh(-image_rolled, w = 150, h = 150, offset = 0.01) %>%
        # Brushing
        opening(makeBrush(11, shape='disc'))
    writeImage(image_threshold, paste0(paste_folder_name("threshold", color_channel), image_name, ".tiff"))
    cat("\tthreshold")

    # 4. Detect round shaped object and remove super small size
    image_object <- bwlabel(image_threshold)
    object_ID_nonround <- detect_nonround_object(image_object, after_watershed = F)
    image_round <- rmObjects(image_object, object_ID_nonround, reenumerate = T)
    writeImage(image_round, paste0(paste_folder_name("round", color_channel), image_name, ".tiff"))
    cat("\tround object")

    # 5. Watershed
    image_distancemap <- distmap(image_round)
    cat("\tdistance map")
    image_watershed <- watershed(image_distancemap, tolerance = 1)

    ## Skip the second watershed step if there is not colony
    if (all(image_watershed == 0)) {
        cat("\tbefore watershed, do not have colony on the plate\t", image_name)
        next
    }

    ## Execute when there is at least one object
    if (!all(image_watershed == 0)){
        ## After watershed, apply a second filter removing objects that are too small to be colonies
        object_ID_nonround2 <- detect_nonround_object(image_watershed, image_rolled, after_watershed = T)
        image_watershed2 <- rmObjects(image_watershed, object_ID_nonround2, reenumerate = T)

        if (all(image_watershed2 == 0)) {
            cat("\tafter watershed, do not have colony on the plate \t", image_name)
            next
        }

        if (!all(image_watershed2 == 0)) {
            save(image_watershed2, file = paste0(paste_folder_name("watershed", color_channel), image_name, ".RData")) # save watersed image object
            writeImage(colorLabels(image_watershed2), paste0(paste_folder_name("watershed", color_channel), image_name, ".tiff"))
            cat("\twatershed\t", i, "/", nrow(list_images), "\t", image_name)
        }

    }

}

