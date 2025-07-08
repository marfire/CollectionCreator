local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrPrefs = import 'LrPrefs'
require 'Utils.lua'

--[[
Terminology:
- A Service is either the local Collections area defined in this catalog or one of the publishing services.
- An Id is the localIdentifier of a Lightroom object - in particular, a Collection, Collection Set, or
publishing service.
- A Location is a table of {serviceId, setId} that uniquely identifies a usable Lightroom location:
a Collection, Collection Set, or the root of a service. serviceId is the localIdentifier of a publishing
service or nil for local collections. setId is the localIdentifier of a Collection or Collection Set or
nil for the service root. From this minimal identifier we can use the API to get all the information we
need about the Location.
- A Path is a string representation of a Location showing the Collection Set hierarchy that leads to it.
Note that this is just used for user display.
]]

local catalog = LrApplication.activeCatalog()
assert(catalog, "No catalog returned by LrApplication.activeCatalog().")

local f = LrView.osFactory()
assert(f, "No factory returned by LrView.osFactory().")

-- Get the Prefs object for our plugin, which allows us to save state between invocations.
local prefs = LrPrefs.prefsForPlugin()
assert(prefs, "No prefs returned by LrPrefs.prefsForPlugin().")

local PrefsKeys = {
    NUM_SOURCES = "numSources",
    SOURCE_COLLECTION_PREFIX = "sourceCollection_",
    SOURCE_NUM_PHOTOS_PREFIX = "sourceNumPhotos_",
    DESTINATION_SET = "destinationSet",
}

local DIALOG_REFRESH_RESULT = "refresh_dialog"
local DEFAULT_NUM_PHOTOS = 10
local DEFAULT_DESTINATION_NAME = os.date("%B %d, %Y")  -- The default name is today's date.

local UIConstants = {
    -- Layout
    FILL_ALL = 1.0,
    CONTROL_SPACING = f:control_spacing(),

    DIALOG_WIDTH = 800,
    DIALOG_MARGIN = 0,
    GROUP_BOX_MARGIN = 15,
    ROW_MARGIN_BOTTOM = 6,

    SOURCE_COLLECTION_FILL = 1.0,
    SOURCE_NUM_PHOTOS_WIDTH = 100,
    SOURCE_TOTAL_PHOTOS_WIDTH = 70,
    SOURCE_BUTTON_WIDTH = 35,

    DESTINATION_SET_FILL = 1.0,
    DESTINATION_NAME_WIDTH = 300,

    -- Fonts
    FONT_SMALL_BOLD = "<system/small/bold>",

    -- Text
    PATH_SEPARATOR = " ⮞ ", -- U+2B9E, THREE-D RIGHTWARDS ARROWHEAD
    SMART_COLLECTION_INDICATOR = " ⚙", -- U+2699, GEAR SYMBOL, similar to what Lightroom uses
    SOURCE_ADD_TITLE = "➕", -- U+2795, HEAVY PLUS SIGN
    SOURCE_REMOVE_TITLE = "❌", -- U+274C, CROSS MARK
}

-- Gets all local collections and returns them in the table format used
-- by Lightroom popups.
local function getLocalCollections()
    -- Recursively descends through nested Collection Sets to get their Collections.
    local function getLocalCollectionsRecursive(parent, pathPrefix)
        local localCollectionsForPopup = {}

        -- First add the Collections directly under this parent.
        local childCollections = parent:getChildCollections()
        for _, collection in ipairs(childCollections) do
            local displayPath = pathPrefix .. collection:getName()
            if collection:isSmartCollection() then
                displayPath = displayPath .. UIConstants.SMART_COLLECTION_INDICATOR
            end
            table.insert(localCollectionsForPopup, {
                value = {serviceId = nil, setId = collection.localIdentifier},
                title = displayPath,
            })
        end

        -- Then add the Collections in any nested Collection Sets.
        local childCollectionSets = parent:getChildCollectionSets()
        for _, set in ipairs(childCollectionSets) do
            local newPath = pathPrefix .. set:getName() .. UIConstants.PATH_SEPARATOR
            local nestedCollections = getLocalCollectionsRecursive(set, newPath)
            Utils.insertTable(localCollectionsForPopup, nestedCollections)
        end

        return localCollectionsForPopup
    end

    -- Recursively get all the local Collections and sort them by Path.
    local localCollectionsForPopup = getLocalCollectionsRecursive(catalog, "")
    table.sort(localCollectionsForPopup, Utils.titleCompare)

    return localCollectionsForPopup
end

-- Gets all destination Collection Sets and returns them in the table format used
-- by Lightroom popups.
local function getDestinationSets()
    -- Gets all destination Collection Sets in a given service, either the local area
    -- or one of the publishing services.
    local function getServiceSets(root, serviceId, serviceTitle)
        -- Recursively descends through nested Collection Sets.
        local function getServiceSetsRecursive(parent, serviceId, pathPrefix)
            local serviceSetsForPopup = {}

            -- Add each child Set, then recursively add its descendants.
            local childSets = parent:getChildCollectionSets()
            for _, set in ipairs(childSets) do
                local newPath = pathPrefix .. UIConstants.PATH_SEPARATOR .. set:getName()
                table.insert(serviceSetsForPopup, {
                    value = {serviceId = serviceId, setId = set.localIdentifier},
                    title = newPath,
                })

                local nestedSetsForPopup = getServiceSetsRecursive(set, serviceId, newPath)
                Utils.insertTable(serviceSetsForPopup, nestedSetsForPopup)
            end

            return serviceSetsForPopup
        end

        -- Start with the root location of the service.
        local serviceSetsForPopup = {{
            value = {serviceId = serviceId, setId = nil},
            title = serviceTitle,
        }}

        -- Now add all the nested Collection Sets and sort the final arrayby Path.
        local nestedSetsForPopup = getServiceSetsRecursive(root, serviceId, "  ")
        table.sort(nestedSetsForPopup, Utils.titleCompare)
        Utils.insertTable(serviceSetsForPopup, nestedSetsForPopup)

        return serviceSetsForPopup
    end

    -- Start the list with the local Collection Sets.
    local destinationSetsForPopup = getServiceSets(catalog, nil, "Local")

    -- Get and alphabetically sort the publishing services.
    local publishServices = catalog:getPublishServices()
    Utils.safeSort(publishServices, function(a, b) return a:getName() < b:getName() end)

    -- Go through each publishing service and add its Collection Sets.
    for _, service in ipairs(publishServices) do
        local serviceTitle = string.format("%s (%s)", service:getName(), service:getPluginId())
        local serviceSetsForPopup = getServiceSets(service, service.localIdentifier, serviceTitle)
        Utils.insertTable(destinationSetsForPopup, serviceSetsForPopup)
    end

    return destinationSetsForPopup
end

-- Gets a publishing service by its id. The API doesn't provide this capability so we have
-- to do it manually. Could instead create a hash table but there should only be a few entries.
-- Returns nil if there is no service with the given id.
local function getServiceById(serviceId)
    local publishServices = catalog:getPublishServices()
    for _, service in ipairs(publishServices) do
        if service.localIdentifier == serviceId then
            return service
        end
    end
end

-- Returns a Collection at the given location. Returns nil if none such exists.
-- Note that this doesn't return Collection Sets.
local function getCollectionByLocation(location)
    if not location.serviceId then
        return catalog:getCollectionByLocalIdentifier(location.setId)
    else
        local service = getServiceById(location.serviceId)
        if service then
            return service:getPublishedCollectionByLocalIdentifier(location.setId)
        end
    end
end

-- Finds a Collection by name in a given parent Collection Set.
-- Returns nil if none such exists.
local function getCollectionByName(parentLocation, name)
    -- First get the parent object based on its Location.
    local parent
    if not parentLocation.serviceId then  -- If the location is local...
        if parentLocation.setId then  -- and there is a parent Collection Set:
            parent = catalog:getCollectionByLocalIdentifier(parentLocation.setId)
        else -- and there isn't a parent Collection Set:
            parent = catalog
        end
    else  -- If the location is from a publishing service...
        if parentLocation.setId then  -- and there is a parent Collection Set:
            parent = catalog:getPublishedCollectionByLocalIdentifier(parentLocation.setId)
        else -- and there isn't a parent Collection Set:
            parent = getServiceById(parentLocation.serviceId)
        end
    end

    -- Now search the parent for a Collection with the given name.
    if parent then
        local collections = parent:getChildCollections()
        for _, collection in ipairs(collections) do
            if collection:getName() == name then
                return collection
            end
        end
    end
end

-- Creates a new Collection at the given location.
-- Assumes parentLocation is valid and that the named Collection doesn't already exist.
local function createCollection(parentLocation, name)
    local parent, collection
    if not parentLocation.serviceId then  -- If the location is local:
        if parentLocation.setId then
            parent = catalog:getCollectionByLocalIdentifier(parentLocation.setId)
            assert(parent, "No collection set found for parent location")
        end

        collection = catalog:createCollection(name, parent, false)
    else  -- If the location is from a publishing service:
        local service = getServiceById(parentLocation.serviceId)
        assert(service, "No service found for parent location")
        if parentLocation.setId then
            parent = catalog:getPublishedCollectionByLocalIdentifier(parentLocation.setId)
            assert(parent, "No collection set found for parent location")
        end

        collection = service:createPublishedCollection(name, parent, false)
    end

    return collection
end

-- Returns an array of randomly sampled photos from the given sources, avoiding duplicates.
-- The input is the array of source entries from props.sources. If numPhotos has a fractional part,
-- that is taken to mean that an additional photo should be sampled with probability equal to the
-- fractional part.
local function samplePhotos(sources)
    local sampledPhotos = {}
    local photoIdSet = {}  -- Use a set to prevent duplicate photos

    for _, sourceProps in ipairs(sources) do
        assert(sourceProps.selectedCollection, "No selected Collection for source.")
        local collection = catalog:getCollectionByLocalIdentifier(sourceProps.selectedCollection.setId)
        assert(collection, "Selected source Collection not found.")

        -- Decide probabilistically how many photos to sample based on the fractional part.
        local rawNumPhotos = sourceProps.numPhotos
        local baseNumPhotos = math.floor(rawNumPhotos)
        local fractionalNumPhotos = rawNumPhotos - baseNumPhotos

        local numPhotosWanted = baseNumPhotos
        if fractionalNumPhotos > 0 and math.random() < fractionalNumPhotos then
            numPhotosWanted = numPhotosWanted + 1
        end

        if numPhotosWanted > 0 then
            -- This performs a partial, in-place shuffle and checks for duplicates on the fly.
            local photos = collection:getPhotos()
            local i, n = 1, #photos
            local numPhotosSampled = 0

            while i <= n and numPhotosSampled < numPhotosWanted do
                -- Pick a random remaining element to consider by swapping it to the current position.
                local j = math.random(i, n)
                photos[i], photos[j] = photos[j], photos[i]

                local candidatePhoto = photos[i]
                if not photoIdSet[candidatePhoto] then
                    table.insert(sampledPhotos, candidatePhoto)
                    photoIdSet[candidatePhoto] = true
                    numPhotosSampled = numPhotosSampled + 1
                end

                i = i + 1
            end
        end
    end

    -- Do a final shuffle of the photos.
    Utils.shuffle(sampledPhotos)
    return sampledPhotos
end

-- Synchronously updates the total photo count for a source.
local function updateTotalPhotos(sourceProps)
    local collection = catalog:getCollectionByLocalIdentifier(sourceProps.selectedCollection.setId)
    assert(collection, "No Collection found for source.")

    local photos = collection:getPhotos()
    sourceProps.totalPhotosText = "of " .. Utils.formatNumber(#photos)
end

-- Asynchronously updates the total photo count for a source.
local function updateTotalPhotosAsync(sourceProps)
    sourceProps.totalPhotosText = "..."  -- Show a loading indicator
    LrTasks.startAsyncTask(function()
        updateTotalPhotos(sourceProps)
    end)
end

-- Synchronously updates the total photo count for all sources.
local function updateAllTotalPhotos(sources)
    for _, sourceProps in ipairs(sources) do
        -- Only fetch if the count is missing.
        if sourceProps.totalPhotosText == "" or sourceProps.totalPhotosText == "..." then
            updateTotalPhotos(sourceProps)
        end
    end
end

-- Creates an observable source props table.
-- We don't populate the totalPhotosText field now because the dialog may be open
-- (if the add source button was just pressed) and we don't want to block the UI.
local function createSourceProps(context, selectedCollection, numPhotos)
    local sourceProps = LrBinding.makePropertyTable(context)

    sourceProps.selectedCollection = selectedCollection
    sourceProps.numPhotos = numPhotos
    sourceProps.totalPhotosText = ""  -- A placeholder

    -- When the user picks a different collection from the dropdown we asynchronously update the count.
    sourceProps:addObserver("selectedCollection", function()
        updateTotalPhotosAsync(sourceProps)
    end)

    return sourceProps
end

-- Creates a source props table with default values.
-- This is used when the user adds a new source row and when the program is run for the first time.
local function createDefaultSourceProps(context, sourceCollectionsForPopup)
    local defaultSourceLocation = sourceCollectionsForPopup[1].value
    local sourceProps = createSourceProps(context, defaultSourceLocation, DEFAULT_NUM_PHOTOS)
    return sourceProps
end

-- Returns true if the given location is a member of the given popup.
local function isPopupMember(location, popup)
    for _, entry in ipairs(popup) do
        if Utils.locationEqual(location, entry.value) then
            return true
        end
    end
    return false
end

-- Initializes the dialog's state (the observable props table) from saved preferences or from defaults.
-- The returned props table has the following structure:
-- - sources: an array of tables, one for each source:
--   - selectedCollection: the Location of the selected source Collection.
--   - numPhotos: the number of photos to sample from the source.
--   - totalPhotosText: a string showing the total number of photos in the source.
-- - destinationSetSelection: the Location of the selected destination Set.
-- - destinationName: the name of the destination Collection.
local function loadPropsFromPrefs(context, sourceCollectionsForPopup, destinationSetsForPopup)
    local props = LrBinding.makePropertyTable(context)

    -- This will be an array of observable tables, one per source.
    props.sources = {}

    -- Since we allow the user to go down to zero rows we need another way to tell that this
    -- is the first run.
    local firstRun = (prefs[PrefsKeys.DESTINATION_SET] == nil)
    if firstRun then
        -- If this is the first run create a default source row.
        local sourceProps = createDefaultSourceProps(context, sourceCollectionsForPopup)
        table.insert(props.sources, sourceProps)
    else
        -- Otherwise load the sources from prefs. We don't know how many there are in advance
        -- so we loop until prefs stops having locations.
        local i = 1
        while true do
            local sourceLocation = prefs[PrefsKeys.SOURCE_COLLECTION_PREFIX .. i]
            if not sourceLocation then
                break
            end

            local numPhotos = prefs[PrefsKeys.SOURCE_NUM_PHOTOS_PREFIX .. i]
            assert(type(numPhotos) == "number" and numPhotos >= 0, "Invalid number of photos.")

            -- If a source Collection no longer exists we just skip that source.
            if isPopupMember(sourceLocation, sourceCollectionsForPopup) then
                local sourceProps = createSourceProps(context, sourceLocation, numPhotos)
                table.insert(props.sources, sourceProps)
            end

            i = i + 1
        end
    end

    -- Select the saved destination set if one is stored in prefs and is valid.
    local destinationSetLocation = prefs[PrefsKeys.DESTINATION_SET]
    if destinationSetLocation and isPopupMember(destinationSetLocation, destinationSetsForPopup) then
        props.destinationSetSelection = destinationSetLocation
    else
        props.destinationSetSelection = destinationSetsForPopup[1].value
    end

    props.destinationName = DEFAULT_DESTINATION_NAME  -- Not saved in prefs.

    return props
end

-- Takes a props table and saves its state to prefs.
local function savePrefsFromProps(props)
    -- Clear existing prefs to ensure that old values aren't left over.
    Utils.clearPrefs(prefs)

    prefs[PrefsKeys.DESTINATION_SET] = props.destinationSetSelection

    for i, source in ipairs(props.sources) do
        prefs[PrefsKeys.SOURCE_COLLECTION_PREFIX .. i] = source.selectedCollection
        prefs[PrefsKeys.SOURCE_NUM_PHOTOS_PREFIX .. i] = source.numPhotos
    end
end

-- The main function that runs when the menu item is selected.
-- Because the dialog is modal we assume throughout that the catalog can't be changed
-- (in particular, that sources and destinations can't be deleted) while this is running,
-- even though that may not technically be true.
local function runCollectionCreator(context)
    -- Get all local Collections for the source popup. Abort if there are none.
    local sourceCollectionsForPopup = getLocalCollections()
    if #sourceCollectionsForPopup == 0 then
        LrDialogs.message("Error", "No collections found to sample from.", "critical")
        return
    end

    -- Get all possible destinations (local and published) for the destination set popup.
    local destinationSetsForPopup = getDestinationSets()
    assert(#destinationSetsForPopup > 0, "No destinations found")

    -- Create the props table holding the dialog's state.
    local props = loadPropsFromPrefs(context, sourceCollectionsForPopup, destinationSetsForPopup)

    -- Because we have to close, recreate, and re-open the dialog for dynamic view changes,
    -- we need to open the dialog in a loop until the user is done.
    while true do
        -- This repeat-until-true loop is a hack to get around Lua's lack of continue or goto.
        -- This allows us to end the dialog re-creation loop with return and continue it with break
        -- (which breaks the repeat loop and allows the while-true loop to continue). This makes the
        -- control flow easier to follow by avoiding a bunch of nested if statements.
        repeat
            -- Synchronously fetch counts for all selected sources. We do this each time the dialog is
            -- built because a row may have just been added. Doing it upfront slows down the initial
            -- display of the dialog but avoids a distracting flash as the counts are populated.
            updateAllTotalPhotos(props.sources)

            -- Build the UI, starting with the source list.
            local sourceRows = {
                fill_horizontal = UIConstants.FILL_ALL,
            }

            -- Add a header row for the source list. Note that we need spacers for missing elements
            -- that exist in the other rows if we want everything to line up.
            table.insert(sourceRows, f:row {
                f:static_text {
                    title = "Collection",
                    fill_horizontal = UIConstants.SOURCE_COLLECTION_FILL,
                    font = UIConstants.FONT_SMALL_BOLD,
                },
                f:static_text {
                    title = "Photos",
                    width = UIConstants.SOURCE_NUM_PHOTOS_WIDTH,
                    font = UIConstants.FONT_SMALL_BOLD,
                },
                f:spacer {
                    width = UIConstants.SOURCE_TOTAL_PHOTOS_WIDTH,
                },
                f:spacer {
                    width = UIConstants.SOURCE_BUTTON_WIDTH,
                },
                spacing = UIConstants.CONTROL_SPACING,
                margin_bottom = UIConstants.ROW_MARGIN_BOTTOM,
                fill_horizontal = UIConstants.FILL_ALL,
            })

            -- Add a row for each source.
            for i, sourceProps in ipairs(props.sources) do
                local currentIndex = i  -- Capture the index for the closure below
                local row = f:row {
                    bind_to_object = sourceProps,
                    f:popup_menu {
                        items = sourceCollectionsForPopup,
                        value = LrView.bind("selectedCollection"),
                        value_equal = Utils.locationEqual,
                        fill_horizontal = UIConstants.SOURCE_COLLECTION_FILL,
                    },
                    f:edit_field {
                        value = LrView.bind("numPhotos"),
                        string_to_value = function(_, s)
                            return tonumber(s)
                        end,
                        validate = function(_, s)
                            local n = tonumber(s)
                            return n and n >= 0, s, "Photos must be a non-negative number"
                        end,
                        width = UIConstants.SOURCE_NUM_PHOTOS_WIDTH,
                    },
                    f:static_text {
                        title = LrView.bind("totalPhotosText"),
                        width = UIConstants.SOURCE_TOTAL_PHOTOS_WIDTH,
                    },
                    f:push_button {
                        title = UIConstants.SOURCE_REMOVE_TITLE,
                        action = function(button)  -- Remove the source row and re-build the dialog.
                            table.remove(props.sources, currentIndex)
                            LrDialogs.stopModalWithResult(button, DIALOG_REFRESH_RESULT)
                        end,
                        width = UIConstants.SOURCE_BUTTON_WIDTH,
                    },
                    spacing = UIConstants.CONTROL_SPACING,
                    margin_bottom = UIConstants.ROW_MARGIN_BOTTOM,
                    fill_horizontal = UIConstants.FILL_ALL,
                }

                table.insert(sourceRows, row)
            end

            -- Add a row for the add source button
            table.insert(sourceRows, f:row {
                f:spacer {
                    fill_horizontal = UIConstants.SOURCE_COLLECTION_FILL,
                },
                f:spacer {
                    width = UIConstants.SOURCE_NUM_PHOTOS_WIDTH,
                },
                f:spacer {
                    width = UIConstants.SOURCE_TOTAL_PHOTOS_WIDTH,
                },
                f:push_button {
                    title = UIConstants.SOURCE_ADD_TITLE,
                    action = function(button)  -- Add a new source row and re-build the dialog.
                        local sourceProps = createDefaultSourceProps(context, sourceCollectionsForPopup)
                        table.insert(props.sources, sourceProps)
                        LrDialogs.stopModalWithResult(button, DIALOG_REFRESH_RESULT)
                    end,
                    width = UIConstants.SOURCE_BUTTON_WIDTH,
                },
                spacing = UIConstants.CONTROL_SPACING,
                fill_horizontal = UIConstants.FILL_ALL,
            })

            -- Create the destination rows.
            local destinationRows = {
                f:row {
                    f:static_text {
                        title = "Collection Set",
                        fill_horizontal = UIConstants.DESTINATION_SET_FILL,
                        font = UIConstants.FONT_SMALL_BOLD,
                    },
                    f:static_text {
                        title = "Collection Name",
                        width = UIConstants.DESTINATION_NAME_WIDTH,
                        font = UIConstants.FONT_SMALL_BOLD,
                    },
                    spacing = UIConstants.CONTROL_SPACING,
                    margin_bottom = UIConstants.ROW_MARGIN_BOTTOM,
                    fill_horizontal = UIConstants.FILL_ALL,
                },
                f:row {
                    f:popup_menu {
                        items = destinationSetsForPopup,
                        value = LrView.bind("destinationSetSelection"),
                        value_equal = Utils.locationEqual,
                        fill_horizontal = UIConstants.DESTINATION_SET_FILL,
                    },
                    f:edit_field {
                        value = LrView.bind("destinationName"),
                        string_to_value = function(_, s)
                            return string.match(s, "^%s*(.-)%s*$")  -- Remove leading and trailing whitespace.
                        end,
                        validate = function(_, s)
                            return s ~= "", s, "Collection Name cannot be empty"
                        end,
                        width = UIConstants.DESTINATION_NAME_WIDTH,
                    },
                    spacing = UIConstants.CONTROL_SPACING,
                    margin_bottom = UIConstants.ROW_MARGIN_BOTTOM,
                    fill_horizontal = UIConstants.FILL_ALL,
                },
                fill_horizontal = UIConstants.FILL_ALL,
            }

            -- Construct and present the dialog.
            local result = LrDialogs.presentModalDialog({
                title = "Collection Creator",
                resizable = false,  -- Not useful since dialog contents are fixed width.
                save_frame = "CollectionCreatorPosition",
                contents = f:column {
                    bind_to_object = props,
                    f:group_box {
                        title = "Sources",
                        f:column(sourceRows),
                        fill_horizontal = UIConstants.FILL_ALL,
                        margin = UIConstants.GROUP_BOX_MARGIN,
                    },
                    f:group_box {
                        title = "Destination",
                        f:column(destinationRows),
                        fill_horizontal = UIConstants.FILL_ALL,
                        margin = UIConstants.GROUP_BOX_MARGIN,
                    },
                    width = UIConstants.DIALOG_WIDTH,
                    margin = UIConstants.DIALOG_MARGIN,
                },
                actionVerb = "Create",
                cancelVerb = "Cancel",
            })

            -- Handle the result of the dialog.
            if result == "ok" then
                local destinationCollection = getCollectionByName(props.destinationSetSelection, props.destinationName)
                if destinationCollection then
                    -- If the destination Collection exists and is a Smart Collection we show an error message.
                    if destinationCollection:isSmartCollection() then
                        LrDialogs.message(
                            "Error",
                            "A smart collection with this name already exists and cannot be overwritten.",
                            "warning"
                        )
                        break  -- redo dialog
                    end

                    -- Otherwise, if the destination Collection exists we prompt to overwrite it.
                    local message = string.format(
                        "A collection named '%s' already exists. Do you want to replace its contents?",
                        props.destinationName
                    )
                    local choice = LrDialogs.confirm("Collection Exists", message, "Replace", "Cancel")
                    if choice ~= "ok" then
                        break  -- redo dialog
                    end
                end
                -- At this point, if destinationCollection exists we know we can overwrite it.

                -- Prepare to write to the catalog.
                catalog:withWriteAccessDo("Create Collection", function()
                    catalog:assertHasWriteAccess()

                    if destinationCollection then  -- We are overwriting an existing Collection.
                        destinationCollection:removeAllPhotos()
                    else -- We are creating a new Collection.
                        destinationCollection = createCollection(props.destinationSetSelection, props.destinationName)

                        if not destinationCollection then
                            error("An unknown error occurred while creating the destination collection.")
                        end
                    end
                    -- At this point an empty destinationCollection exists.

                    -- Sample the photos and add them to the destination Collection.
                    local sampledPhotos = samplePhotos(props.sources)
                    if #sampledPhotos > 0 then
                        destinationCollection:addPhotos(sampledPhotos)
                    end

                    -- Save preferences for next time.
                    savePrefsFromProps(props)
                end)

                -- The write operation is complete. Now, find the collection again by name
                -- to get a valid Collection object, and then set it as the active source.
                local collectionCreated = getCollectionByName(props.destinationSetSelection, props.destinationName)

                if collectionCreated then
                    catalog:setActiveSources({collectionCreated})
                    LrApplicationView.gridView()
                end

                return
            elseif result == "cancel" then
                return
            end  -- DIALOG_REFRESH_RESULT will just let the loop continue.
        until true
    end

end

-- When this file is loaded we start a background task and create a context
-- in order to show the dialog.
LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("showCollectionCreatorDialogContext", runCollectionCreator)
end)