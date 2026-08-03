-- fnaf_lib.lua
-- Общая библиотека функций для FNAF-режима. Загружается по ссылке каждым скриптом ночи.

local SS13 = require("SS13")

local lib = {}

function lib.get_client_by_ckey(ckey)
    local normalized = dm.global_procs._ckey(ckey)
    return dm.global_vars.GLOB.directory[normalized]
end

local soundsByHttp = {}
function lib.loadSound(http)
    if soundsByHttp[http] then return soundsByHttp[http] end
    local request = SS13.new("/datum/http_request")
    local file_name = "tmp/fnaf_sound_" .. tostring(#soundsByHttp) .. ".ogg"
    request:prepare("get", http, "", "", file_name)
    request:begin_async()
    while request:is_complete() == 0 do SS13.wait(1) end
    local snd = SS13.new("/sound", file_name)
    if not snd then return nil end
    soundsByHttp[http] = snd
    return snd
end

local iconsByHttp = {}
function lib.loadIcon(http)
    if iconsByHttp[http] then return iconsByHttp[http] end
    local request = SS13.new("/datum/http_request")
    local file_name = "tmp/fnaf_icon_" .. tostring(#iconsByHttp) .. ".dmi"
    request:prepare("get", http, "", "", file_name)
    request:begin_async()
    while request:is_complete() == 0 do SS13.wait(1) end
    local icon = SS13.new("/icon", file_name)
    if not icon then return nil end
    iconsByHttp[http] = icon
    return icon
end

function lib.loadMapFile(http)
    local request = SS13.new("/datum/http_request")
    local file_name = "tmp/fnaf_template.dmm"
    request:prepare("get", http, "", "", file_name)
    request:begin_async()
    while request:is_complete() == 0 do SS13.wait(1) end
    SS13.wait(2)
    return file_name
end

function lib.play_sound(source, snd)
    if source and snd then
        dm.global_procs.playsound(source, snd, 100, TRUE, -1)
    end
end

function lib.get_apc_charge(apc_obj)
    local ok, cell = pcall(function() return apc_obj.cell end)
    if not ok or not cell then return nil end
    local ok_charge, charge_val = pcall(function() return cell:charge() end)
    if not ok_charge then return nil end
    return charge_val
end

function lib.set_apc_charge(apc_obj, new_value)
    local ok, cell = pcall(function() return apc_obj.cell end)
    if not ok or not cell then return false end
    local ok_set, err = pcall(function() cell.charge = new_value end)
    return ok_set, err
end

function lib.reset_apc_for_night(apc_obj, debug_log)
    if not apc_obj then return end

    local ok_cell, cell = pcall(function() return apc_obj.cell end)
    if not ok_cell or not cell then
        debug_log("reset_apc_for_night: не удалось получить cell")
        return
    end

    local ok_maxcharge, maxcharge = pcall(function() return cell.maxcharge end)
    if ok_maxcharge and maxcharge then
        local ok_set, err = pcall(function() cell.charge = maxcharge end)
        debug_log(ok_set and ("Заряд APC сброшен на максимум: " .. tostring(maxcharge))
                          or ("Не удалось сбросить заряд: " .. tostring(err)))
    else
        debug_log("Не удалось прочитать maxcharge")
    end

    local ok_channels, err_channels = pcall(function()
        apc_obj.equipment = 2
        apc_obj.lighting = 2
        apc_obj.environ = 2
    end)
    debug_log(ok_channels and "Каналы APC выставлены: equipment=2, lighting=2, environ=2"
                          or ("Не удалось выставить каналы APC: " .. tostring(err_channels)))
end

function lib.has_prefix(type_str, prefix)
    if string.sub(type_str, 1, string.len(prefix)) ~= prefix then return false end
    local next_char = string.sub(type_str, string.len(prefix) + 1, string.len(prefix) + 1)
    return next_char == "" or next_char == "/"
end

-- Единый скан area: находит APC, поддори по именам, и все нужные landmark'и
function lib.scan_area(area, needed_markers, needed_doors, debug_log)
    local ok_total, total = pcall(function() return #area.contents end)
    if not ok_total or not total then
        debug_log("Не удалось получить длину area.contents")
        return nil, {}, {}
    end

    debug_log("area.contents length: " .. tostring(total))

    local apc = nil
    local landmark_turfs = {}
    local power_doors = {}

    for i = 1, total do
        local ok_obj, obj = pcall(function() return area.contents[i] end)

        if ok_obj and obj then
            local ok_type, type_str = pcall(function() return tostring(obj.type) end)
            if ok_type and type_str then
                if not apc and lib.has_prefix(type_str, "/obj/machinery/power/apc") then
                    apc = obj
                end

                if lib.has_prefix(type_str, "/obj/machinery/door/poddoor") then
                    local ok_name, name = pcall(function() return obj.name end)
                    if ok_name and name and needed_doors[name] and not power_doors[name] then
                        power_doors[name] = obj
                    end
                end

                if lib.has_prefix(type_str, "/obj/effect/landmark") then
                    local ok_name, name = pcall(function() return obj.name end)
                    if ok_name and name and needed_markers[name] and not landmark_turfs[name] then
                        landmark_turfs[name] = obj.loc
                    end
                end
            end
        end

        if i % 200 == 0 then
            debug_log("Сканирование: " .. tostring(i) .. "/" .. tostring(total))
            SS13.wait(1)
        end
    end

    return apc, power_doors, landmark_turfs
end

function lib.spawn_animatronic(turf, animatronic_data)
    local mob = SS13.new("/mob/living", turf)
    if not mob or not SS13.is_valid(mob) then return nil end
    mob.name = animatronic_data.display_name
    mob.real_name = animatronic_data.display_name
    if animatronic_data.icon then
        mob.icon = animatronic_data.icon
    end
    mob.icon_state = "test"
    mob:add_traits({"godmode"})
    return mob
end

function lib.move_animatronic(animatronic_data, marker_name, landmark_turfs, target_mob, debug_log)
    local turf = landmark_turfs[marker_name]
    if not turf then
        debug_log("Landmark '" .. marker_name .. "' отсутствует в кэше для " .. animatronic_data.display_name)
        return
    end

    if not animatronic_data.mob or not SS13.is_valid(animatronic_data.mob) then
        animatronic_data.mob = lib.spawn_animatronic(turf, animatronic_data)
        debug_log(animatronic_data.display_name .. " заспавнен на '" .. marker_name .. "'")
    else
        local ok, err = pcall(function()
            animatronic_data.mob.loc = turf
        end)
        debug_log(ok and (animatronic_data.display_name .. " телепортирован на '" .. marker_name .. "'")
                      or ("Не удалось телепортировать " .. animatronic_data.display_name .. ": " .. tostring(err)))
    end

    lib.play_sound(target_mob, animatronic_data.sound)
end

function lib.is_door_closed(door_obj)
    if not door_obj then return false end
    local ok, density = pcall(function() return door_obj.density end)
    return ok and density and density ~= 0
end

function lib.drain_apc(apc_obj, amount, debug_log)
    if not apc_obj then return end

    local current = lib.get_apc_charge(apc_obj)
    if not current then
        debug_log("Не удалось прочитать текущий заряд APC")
        return
    end

    local new_charge = current - amount
    if new_charge < 0 then new_charge = 0 end

    local ok_set, err = lib.set_apc_charge(apc_obj, new_charge)
    if not ok_set then
        debug_log("Не удалось записать новый заряд APC: " .. tostring(err))
    end
end

function lib.force_open_all_doors(power_doors, door_names)
    for _, dname in ipairs(door_names) do
        local door_obj = power_doors[dname]
        if door_obj then
            pcall(function() door_obj:open() end)
        end
    end
end

function lib.open_all_doors(power_doors, door_names, debug_log)
    for _, dname in ipairs(door_names) do
        local door_obj = power_doors[dname]
        if door_obj then
            local ok, err = pcall(function() door_obj:open() end)
            debug_log(ok and ("Дверь '" .. dname .. "' открыта")
                          or ("Не удалось открыть '" .. dname .. "': " .. tostring(err)))
        end
    end
end

return lib