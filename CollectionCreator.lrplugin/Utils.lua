Utils = {}

-- Inserts the contents of t2 into t1.
function Utils.insertTable(t1, t2)
    for _, v in ipairs(t2) do
        table.insert(t1, v)
    end

    return t1
end

-- Shuffles an array in place.
function Utils.shuffle(array)
    for i = #array, 2, -1 do
        local j = math.random(i)
        array[i], array[j] = array[j], array[i]
    end
end

-- Sorts a table in place using insertion sort.
-- This is a necessary alternative to table.sort() if comp call yield,
-- since table.sort() is a C function and doesn't allow that. Note that
-- many parts of the Lightroom API call yield.
function Utils.safeSort(t, comp)
    comp = comp or function(a, b) return a < b end

    for i = 2, #t do
        local key = t[i]
        local j = i - 1

        while j >= 1 and comp(key, t[j]) do
            t[j + 1] = t[j]
            j = j - 1
        end
        t[j + 1] = key
    end
end

-- Formats a number with commas.
function Utils.formatNumber(num)
    local str = tostring(num)
    local result = ""
    
    for i = #str, 1, -1 do
        if #result > 0 and #result % 4 == 3 then
            result = "," .. result
        end
        result = str:sub(i, i) .. result
    end
    
    return result
end

-- Formats today's date as a string.
function Utils.formatDate()
    -- %e inserts an extra space instead of a 0, so we need to remove it.
    return os.date("%B %e, %Y"):gsub("%s+", " ")
end

-- Compares two objects by their title field.
function Utils.titleCompare(a, b)
    return a.title < b.title
end

-- Compares two Locations for equality.
function Utils.locationEqual(a, b)
    return a.serviceId == b.serviceId and a.setId == b.setId
end

-- Clears all prefs.
-- Note that you have to use prefs:pairs().
function Utils.clearPrefs(prefs)
    for k, _ in prefs:pairs(prefs) do
        prefs[k] = nil
    end
end