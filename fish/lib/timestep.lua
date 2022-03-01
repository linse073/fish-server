local skynet_m = require "skynet_m"
local timer = require "timer"
local share = require "share"
local loop_time = require "loop_data"
local util = require "util"

local string = string
local pairs = pairs
local ipairs = ipairs
local table = table
local math = math

local game_mode = skynet_m.getenv("game_mode")

local MAX_USER = 4
local ACTIVITY_TIMEOUT = 60 * 100 * 30
-- local SPLINE_INTERVAL = 25
local FROZEN_TIME = 15
local BOSS_EVENT_DELAY = 9

local message
local s_to_c
local c_to_s_i
local error_code
local fish_data
local spline_data
local event_data
local define
local event_type
local fish_type
local skill_status
local camera_spline
local camera_boss_spline
local matrix_data
local skill_data
local item_type
local item_id_map
local fish_born
local fish_koi

local agent_mgr
local game_message
local event_function
local skill_function
local item_function

skynet_m.init(function()
    agent_mgr = skynet_m.queryservice("agent_mgr")
    if game_mode == "fake_game" then
        game_message = skynet_m.queryservice("fake_message")
    else
        game_message = skynet_m.queryservice("game_message")
    end
    message = share.message
    s_to_c = message.s_to_c
    c_to_s_i = message.c_to_s_i
    error_code = message.error_code
    fish_data = share.fish_data
    spline_data = share.spline_data
    event_data = share.event_data
    define = share.define
    event_type = define.event_type
    fish_type = define.fish_type
    skill_status = define.skill_status
    item_type = define.item_type
    item_id_map = define.item_id_map
    camera_spline = share.camera_spline
    camera_boss_spline = share.camera_boss_spline
    matrix_data = share.matrix_data
    skill_data = share.skill_data
    fish_born = share.fish_born
    fish_koi = share.fish_koi
    event_function = {
        [event_type.active_scene_spline] = function(self, info)
            self._spline[info.spline_id] = info
        end,
        [event_type.deactive_scene_spline] = function(self, info)
            self._spline[info.spline_id] = nil
        end,
        [event_type.active_camera_spline] = function(self, info)
            self._use_follow_spline = true
        end,
        [event_type.deactive_camera_spline] = function(self, info)
            self._use_follow_spline = false
        end,
        [event_type.active_fish] = function(self, info)
            local data = fish_data[info.fish_id]
            if info.spline_id > 0 or util.is_boss(info.fish_id) then
                local ready = self._fish_pool[data.type].ready
                ready[#ready+1] = {info, data}
            else
                local pool = self._fish_pool[data.type].pool
                pool[#pool+1] = {info, data}
            end
        end,
        [event_type.deactive_fish] = function(self, info)
            local data = fish_data[info.fish_id]
            local pool = self._fish_pool[data.type].pool
            for i = #pool, 1, -1 do
                if pool[i][1].fish_id == info.fish_id then
                    table.remove(pool, i)
                end
            end
        end,
        [event_type.fight_boss] = function(self, info)
            local event = self._event
            event.info = info
            event.time = self._game_time - info.time
            if info.fish_id > 0 then
                local fdata = fish_data[info.fish_id]
                local sdata = skill_data[info.fish_id]
                local data = {
                    fish_data = fdata,
                    skill_data = sdata,
                }
                if sdata then
                    local rand_skill = {}
                    for i = 1, #sdata.skill - 1 do
                        rand_skill[#rand_skill+1] = i
                    end
                    if sdata.rand_skill then
                        util.shuffle(rand_skill)
                    end
                    rand_skill[#rand_skill+1] = #sdata.skill
                    data.rand_skill = rand_skill
                    data.skill_index = 1
                    data.skill_info = sdata.skill[rand_skill[data.skill_index]]
                    data.skill_time = sdata.born_time
                    if data.skill_info.fish_id > 0 or data.skill_time > 0 then
                        data.skill_status = skill_status.idle
                    else
                        data.skill_status = skill_status.ready
                    end
                end
                for k, v in pairs(self._fish) do
                    if v.fish_id == info.fish_id then
                        data.fish = v
                        break
                    end
                end
                if not data.fish then
                    local ready = self._fish_pool[fdata.type].ready
                    local find = false
                    for k, v in ipairs(ready) do
                        if v[1].fish_id == info.fish_id then
                            find = true
                            break
                        end
                    end
                    if not find then
                        skynet_m.log(string.format("Can't find target fish[%d] of event[%d].", info.fish_id, info.id))
                    end
                end
                event.data = data
            end
            local msg = string.pack(">I2>I4>f", s_to_c.trigger_event, info.id, info.duration - event.time)
            self:broadcast(msg)
        end,
        [event_type.max_small_fish] = function(self, info)
            self._fish_pool[fish_type.small_fish].max_count = info.num
        end,
        [event_type.max_big_fish] = function(self, info)
            self._fish_pool[fish_type.big_fish].max_count = info.num
        end,
    }
    skill_function = {
        [skill_status.idle] = function(self, data, etime, new_fish)
            data.skill_time = data.skill_time - etime
            if data.skill_time <= 0 then
                local fish_id = data.skill_info.fish_id
                if fish_id > 0 then
                    if not data.trigger_fish and data.fish then
                        data.trigger_fish = self:new_skill_trigger_fish(fish_id, 0, new_fish)
                    end
                else
                    data.skill_time = 0
                    data.skill_status = skill_status.ready
                end
            end
        end,
        [skill_status.ready] = function(self, data, etime, new_fish)
            if data.fish then
                local fish_skill = data.rand_skill[data.skill_index]
                skynet_m.log(string.format("cast skill %d", fish_skill))
                data.skill_fish = {}
                data.skill_damage = 1
                data.fish_index = 1
                data.hit_count = 0
                data.skill_time = 0
                data.skill_status = skill_status.cast
                if data.trigger_user then
                    local msg = string.pack(">I2>I4>I2>I4", s_to_c.cast_skill, data.fish.id, fish_skill,
                                            data.trigger_user)
                    self:broadcast(msg)
                else
                    local msg = string.pack(">I2>I4>I2>I4", s_to_c.cast_skill, data.fish.id, fish_skill, 0)
                    self:broadcast(msg)
                end
                local fish_pool = data.skill_info.fish
                while data.fish_index <= #fish_pool do
                    local fish_info = fish_pool[data.fish_index]
                    if data.skill_time < fish_info.time then
                        break
                    end
                    self:new_skill_fish(fish_info, data.skill_time - fish_info.time, data.skill_fish, new_fish)
                    data.fish_index = data.fish_index + 1
                end
            end
        end,
        [skill_status.cast] = function(self, data, etime, new_fish)
            data.skill_time = data.skill_time + etime
            if data.skill_time >= data.skill_info.duration then
                if data.fish and (data.skill_damage > data.skill_info.damage_count
                        or data.skill_time >= data.skill_info.duration + 3) then
                    if data.skill_damage <= data.skill_info.damage_count then
                        if data.trigger_user then
                            local tuser = self._user[data.trigger_user]
                            if tuser then
                                skynet_m.send_lua(game_message, "send_skill_timeout", {
                                    tableid = self._room_id,
                                    seatid = tuser.pos - 1,
                                    userid = tuser.user_id,
                                })
                            else
                                skynet_m.log(string.format("Can't find trigger user %d.", data.trigger_user))
                            end
                        else
                            skynet_m.log("Can't find trigger user.")
                        end
                    end
                    local del_count, del_msg, kill_msg = 0, "", ""
                    for k, v in pairs(data.skill_fish) do
                        self:delete_fish(v, 0)
                        del_count = del_count + 1
                        del_msg = del_msg .. string.pack(">I4>I4", k, v.fish_id)
                        kill_msg = kill_msg .. string.pack("<I4", k)
                    end
                    local msg = string.pack(">I2>I4B", s_to_c.end_skill, data.fish.id, 0)
                    self:broadcast(msg)
                    skynet_m.log(string.format("End skill %d", data.rand_skill[data.skill_index]))
                    if data.skill_index < #data.rand_skill then
                        data.skill_time = data.skill_info.delay
                        data.skill_index = data.skill_index + 1
                        data.skill_info = data.skill_data.skill[data.rand_skill[data.skill_index]]
                        if data.skill_info.fish_id > 0 or data.skill_time > 0 then
                            data.skill_status = skill_status.idle
                        else
                            data.skill_status = skill_status.ready
                        end
                    else
                        data.skill_time = 0
                        data.skill_index = nil
                        data.skill_info = nil
                        data.skill_status = skill_status.done
                        local event = self._event
                        event.time = event.info.duration - BOSS_EVENT_DELAY
                        self:delete_fish(data.fish, 0)
                        del_count = del_count + 1
                        del_msg = del_msg .. string.pack(">I4>I4", data.fish.id, data.fish.fish_id)
                        data.fish = nil
                    end
                    if del_count > 0 then
                        if del_count > 100 then
                            skynet_m.log("Kill fish exceed max count.")
                        end
                        for i = del_count + 1, 100 do
                            kill_msg = kill_msg .. string.pack("<I4", 0)
                        end
                        skynet_m.send_lua(game_message, "send_kill_fish", {
                            tableid = self._room_id,
                            fish = kill_msg,
                        })
                        del_msg = string.pack(">I2>I2", s_to_c.delete_fish, del_count) .. del_msg
                        self:broadcast(del_msg)
                    end
                    data.skill_fish = nil
                    data.skill_damage = nil
                    data.trigger_user = nil
                    data.fish_index = nil
                    data.hit_count = nil
                end
            else
                local fish_pool = data.skill_info.fish
                while data.fish_index <= #fish_pool do
                    local fish_info = fish_pool[data.fish_index]
                    if data.skill_time < fish_info.time then
                        break
                    end
                    self:new_skill_fish(fish_info, data.skill_time - fish_info.time, data.skill_fish, new_fish)
                    data.fish_index = data.fish_index + 1
                end
            end
        end,
        [skill_status.done] = function(self, data, etime, new_fish)
        end,
    }
    item_function = {
        [item_type.frozen] = function(self, info)
            local item_info = {
                item_id = info.probid,
                num = info.probCount,
                time = 0,
                user_id = info.userid,
            }
            self._item[#self._item+1] = item_info
            local msg = string.pack(">I2>I4>I4>I4>f", s_to_c.use_item, info.userid, info.probid, info.probCount,
                                    FROZEN_TIME)
            self:broadcast(msg)
            for k, v in pairs(self._fish) do
                v.frozen = true;
            end
        end,
    }
end)

local timestep = {}

function timestep:init(room_id)
    self._room_id = room_id
    self._user = {}
    self._pos = {}
    self._count = 0
    self._ready_count = 0
    self:clear()
    self._check_func = function()
        self:checkActivity()
        timer.done_routine("timestep_check")
    end
    self._update_func = function()
        self:update()
        timer.done_routine("timestep_update")
    end
end

function timestep:join(user_id, free_pos, agent)
    self:kick(user_id)
    if self._count >= MAX_USER then
        skynet_m.log("Max user.")
        return false
    end
    free_pos = free_pos + 1
    if free_pos <= 0 or free_pos > MAX_USER then
        skynet_m.log(string.format("Illegal pos %d.", free_pos))
        return false
    end
    local now = skynet_m.now()
    local info = {
        user_id = user_id,
        agent = agent,
        ready = false,
        pos = free_pos,
        status_time = now,
        bullet = {},
        cannon = 0,
    }
    self._user[user_id] = info
    self._pos[free_pos] = info
    self._count = self._count + 1
    -- NOTICE: game server notify user leave
    -- timer.add_routine("timestep_check", self._check_func, 100)
    return true
end

function timestep:join_01(user_id, agent)
    self:kick(user_id)
    if self._count >= MAX_USER then
        skynet_m.log("Max user.")
        return false
    end
    local free_pos = 0
    for i = 1, MAX_USER do
        if not self._pos[i] then
            free_pos = i
            break
        end
    end
    if free_pos == 0 then
        skynet_m.log("No free pos.")
        return false
    end
    local now = skynet_m.now()
    local info = {
        user_id = user_id,
        agent = agent,
        ready = false,
        pos = free_pos,
        status_time = now,
        bullet = {},
        cannon = 0,
    }
    self._user[user_id] = info
    self._pos[free_pos] = info
    self._count = self._count + 1
    timer.add_routine("timestep_check", self._check_func, 100)
    return true
end

function timestep:checkActivity()
    local now = skynet_m.now()
    for k, v in pairs(self._user) do
        if now - v.status_time >= ACTIVITY_TIMEOUT then
            skynet_m.send_lua(agent_mgr, "quit", k, error_code.low_activity)
        end
    end
end

function timestep:clear()
    self._last_time = 0
    self._bullet_id = 0
    self._bullet = {}
    self._game_time = 0
    self._fish_id = 1000
    self._group_id = 0
    self._fish = {}
    self._spline = {}
    self._spline_cd = {}
    self._fish_pool = {
        [fish_type.small_fish] = {
            pool = {},
            count = 0,
            max_count = 50,
            time = 0,
            interval = 1,
            rand_min = 5,
            rand_max = 10,
            ready = {},
        },
        [fish_type.big_fish] = {
            pool = {},
            count = 0,
            max_count = 10,
            time = 0,
            interval = 1,
            rand_min = 1,
            rand_max = 1,
            ready = {},
        },
        [fish_type.boss_fish] = {
            pool = {},
            ready = {},
            fish = {},
            count = 0,
        },
    }
    self._event = {
        index = 1,
        time = 0,
        info = nil,
    }
    self._item = {}
    self._use_follow_spline = true
    -- self._spline_time = 0
    self._born_time = fish_born.cd
    self._rand_fish = {0, 0, 0}
    self._delay_msg = {}
    self._koi_fish = {}
    timer.del_all()
end

function timestep:new_fish_id()
    if self._fish_id >= 2147483648 then -- INT32_MAX: 2147483648
        self._fish_id = 1000
    end
    self._fish_id = self._fish_id + 1
    return self._fish_id
end

function timestep:new_bullet_id()
    if self._bullet_id >= 2147483648 then -- INT32_MAX: 2147483648
        self._bullet_id = 0
    end
    self._bullet_id = self._bullet_id + 1
    return self._bullet_id
end

function timestep:new_group_id()
    if self._group_id >= 2147483648 then -- INT32_MAX: 2147483648
        self._group_id = 0
    end
    self._group_id = self._group_id + 1
    return self._group_id
end

function timestep:loop()
    self._event.index = 1
    local small_pool = self._fish_pool[fish_type.small_fish]
    small_pool.pool = {}
    small_pool.max_count = 40
    local big_pool = self._fish_pool[fish_type.big_fish]
    big_pool.pool = {}
    big_pool.max_count = 10
    local boss_pool = self._fish_pool[fish_type.boss_fish]
    boss_pool.pool = {}
    self._spline = {}
    self._spline_cd = {}
    self._use_follow_spline = true
end

function timestep:start()
    self._last_time = skynet_m.now()
    timer.add_routine("timestep_update", self._update_func, 10)
    math.randomseed(self._last_time)
    self:update()
end

function timestep:new_skill_trigger_fish(fish_id, time, new_fish)
    local data = fish_data[fish_id]
    local gid = self:new_group_id()
    local spline_id = 0
    local life_time = data.life_time
    local matrix_id = 0
    local fid = self:new_fish_id()
    local new_info = {
        id = fid,
        fish_id = fish_id,
        spline_id = spline_id,
        group_id = gid,
        speed = 0,
        life_time = life_time,
        time = time,
        data = data,
        matrix_id = matrix_id,
        group_index = 0,
        offset = util.rand_offset(-data.matrix_radius, data.matrix_radius),
        rand_fish = 0,
    }
    new_fish[#new_fish+1] = new_info
    self._fish[fid] = new_info
    -- skynet_m.log(string.format("new skill trigger fish %d %d.", fish_id, fid))
    return new_info
end

function timestep:new_skill_fish(info, time, skill_fish, new_fish)
    local data = fish_data[info.fish_id]
    local gid = self:new_group_id()
    local spline_id = info.spline_id
    if spline_id > 0 then
        self._spline_cd[spline_id] = { cd = 10 }
    end
    local life_time = data.life_time
    if life_time == 0 and spline_id > 0 and info.speed > 0 then
        life_time = spline_data[spline_id].length / info.speed
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    for i = 1, info.num do
        local fid = self:new_fish_id()
        local new_info = {
            id = fid,
            fish_id = info.fish_id,
            spline_id = spline_id,
            group_id = gid,
            speed = info.speed,
            life_time = life_time,
            time = time,
            data = data,
            matrix_id = matrix_id,
            group_index = i - 1,
            offset = util.rand_offset(-data.matrix_radius, data.matrix_radius),
            rand_fish = 0,
        }
        new_fish[#new_fish+1] = new_info
        self._fish[fid] = new_info
        if info.in_count then
            skill_fish[fid] = new_info
        end
    end
end

function timestep:new_spline_fish(info, data, num, spline_id, new_fish)
    local gid = self:new_group_id()
    if spline_id > 0 then
        self._spline_cd[spline_id] = { cd = 15 }
    end
    local life_time = data.life_time
    if life_time == 0 and spline_id > 0 and info.speed > 0 then
        life_time = spline_data[spline_id].length / info.speed
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    for i = 1, num do
        local fid = self:new_fish_id()
        local new_info = {
            id = fid,
            fish_id = info.fish_id,
            spline_id = spline_id,
            group_id = gid,
            speed = info.speed,
            life_time = life_time,
            time = 0,
            data = data,
            matrix_id = matrix_id,
            group_index = i - 1,
            offset = util.rand_offset(-data.matrix_radius, data.matrix_radius),
            rand_fish = 0,
        }
        new_fish[#new_fish+1] = new_info
        self._fish[fid] = new_info
    end
end

function timestep:new_born_fish(info, data, num, new_fish)
    local gid = self:new_group_id()
    local spline_id = 0
    local rand_spline, all_spline = {}, {}
    for k, v in pairs(camera_boss_spline) do
        if not self._spline_cd[k] then
            rand_spline[#rand_spline+1] = k
        end
        all_spline[#all_spline+1] = k
    end
    if #rand_spline > 0 then
        spline_id = rand_spline[math.random(#rand_spline)]
    elseif #all_spline > 0 then
        spline_id = all_spline[math.random(#all_spline)]
    end
    if spline_id > 0 then
        self._spline_cd[spline_id] = { cd = 15 }
    end
    local life_time = data.life_time
    local speed = 0
    if life_time > 0 and spline_id > 0 then
        speed = spline_data[spline_id].length / life_time
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    for i = 1, num do
        local fid = self:new_fish_id()
        local new_info = {
            id = fid,
            fish_id = info.fish_id,
            spline_id = spline_id,
            group_id = gid,
            speed = speed,
            life_time = life_time,
            time = 0,
            data = data,
            matrix_id = matrix_id,
            group_index = i - 1,
            offset = util.rand_offset(-data.matrix_radius, data.matrix_radius),
            born_fish = true,
            rand_fish = 0,
        }
        new_fish[#new_fish+1] = new_info
        self._fish[fid] = new_info
    end
end

function timestep:new_koi_fish(info, data, num, new_fish)
    local gid = self:new_group_id()
    local spline_id = 0
    local rand_spline, all_spline = {}, {}
    for k, v in pairs(camera_boss_spline) do
        if not self._spline_cd[k] then
            rand_spline[#rand_spline+1] = k
        end
        all_spline[#all_spline+1] = k
    end
    if #rand_spline > 0 then
        spline_id = rand_spline[math.random(#rand_spline)]
    elseif #all_spline > 0 then
        spline_id = all_spline[math.random(#all_spline)]
    end
    if spline_id > 0 then
        self._spline_cd[spline_id] = { cd = 15 }
    end
    local life_time = data.life_time
    local speed = 0
    if life_time > 0 and spline_id > 0 then
        speed = spline_data[spline_id].length / life_time
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    for i = 1, num do
        local fid = self:new_fish_id()
        local new_info = {
            id = fid,
            fish_id = info.fish_id,
            spline_id = spline_id,
            group_id = gid,
            speed = speed,
            life_time = life_time,
            time = 0,
            data = data,
            matrix_id = matrix_id,
            group_index = i - 1,
            offset = util.rand_offset(-data.matrix_radius, data.matrix_radius),
            rand_fish = 0,
        }
        new_fish[#new_fish+1] = new_info
        self._fish[fid] = new_info
        self._koi_fish[fid] = new_info
        -- util.dump(new_info)
    end
end

function timestep:update_spline_fish(spline_info, new_fish)
    local small_info = self._fish_pool[fish_type.small_fish]
    local small_pool = small_info.pool
    local big_info = self._fish_pool[fish_type.big_fish]
    local big_pool = big_info.pool
    local total_count = #small_pool + #big_pool
    if total_count > 0 then
        local rand_num = math.random(total_count)
        local info, num
        if rand_num <= #small_pool then
            info = small_pool[rand_num]
            num = math.random(small_info.rand_min, small_info.rand_max)
        else
            info = big_pool[rand_num - #small_pool]
            num = math.random(big_info.rand_min, big_info.rand_max)
        end
        self:new_spline_fish(info[1], info[2], num, spline_info.spline_id, new_fish)
    end
end

function timestep:update_spline(new_fish)
    for k, v in pairs(self._spline) do
        if not self._spline_cd[k] then
            self:update_spline_fish(v, new_fish)
        end
    end
end

function timestep:new_fish(info, data, num, time, new_fish, incount)
    local gid = self:new_group_id()
    local spline_id = info.spline_id
    local life_time = data.life_time
    if spline_id == 0 and life_time == 0 then
        local rand_spline, all_spline = {}, {}
        for k, v in pairs(camera_spline) do
            if not self._spline_cd[k] then
                rand_spline[#rand_spline+1] = k
            end
            all_spline[#all_spline+1] = k
        end
        if #rand_spline > 0 then
            spline_id = rand_spline[math.random(#rand_spline)]
        elseif #all_spline > 0 then
            spline_id = all_spline[math.random(#all_spline)]
        end
    end
    if spline_id > 0 then
        self._spline_cd[spline_id] = { cd = 10 }
    end
    if life_time == 0 and spline_id > 0 and info.speed > 0 then
        life_time = spline_data[spline_id].length / info.speed
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    for i = 1, num do
        local fid = self:new_fish_id()
        local new_info = {
            id = fid,
            fish_id = info.fish_id,
            spline_id = spline_id,
            group_id = gid,
            speed = info.speed,
            life_time = life_time,
            time = time,
            data = data,
            matrix_id = matrix_id,
            incount = incount,
            group_index = i - 1,
            offset = util.rand_offset(-data.matrix_radius, data.matrix_radius),
            rand_fish = 0,
        }
        new_fish[#new_fish+1] = new_info
        self._fish[fid] = new_info
    end
end

function timestep:update_fish(etime, pool_info, new_fish, rand_fish)
    pool_info.time = pool_info.time + etime
    if self._use_follow_spline then
        if (pool_info.time >= pool_info.interval and pool_info.count < pool_info.max_count)
                or pool_info.count < pool_info.max_count * 10 // 8 then
            local pool = pool_info.pool
            if #pool > 0 then
                local info = pool[math.random(#pool)]
                local num = math.random(pool_info.rand_min, pool_info.rand_max)
                local len = #new_fish
                self:new_fish(info[1], info[2], num, 0, new_fish, true)
                pool_info.count = pool_info.count + num
                if rand_fish then
                    for k, v in ipairs(self._rand_fish) do
                        if v == 0 then
                            local rand_num = math.random(num)
                            local fish_info = new_fish[len + rand_num]
                            fish_info.rand_fish = k
                            self._rand_fish[k] = v + 1
                            break
                        end
                    end
                end
            end
            pool_info.time = 0
        end
    end
    if #pool_info.ready > 0 then
        for k, v in ipairs(pool_info.ready) do
            local num = math.random(pool_info.rand_min, pool_info.rand_max)
            local info = v[1]
            local time = self._game_time - info.time
            self:new_fish(info, v[2], num, time, new_fish)
            -- NOTICE: don't count fish
        end
        pool_info.ready = {}
    end
end

function timestep:new_boss(info, data, time, new_fish, pool, incount)
    local gid = self:new_group_id()
    local spline_id = info.spline_id
    local life_time = data.life_time
    if spline_id == 0 and life_time == 0 then
        local rand_spline, all_spline = {}, {}
        for k, v in pairs(camera_boss_spline) do
            if not self._spline_cd[k] then
                rand_spline[#rand_spline+1] = k
            end
            all_spline[#all_spline+1] = k
        end
        if #rand_spline > 0 then
            spline_id = rand_spline[math.random(#rand_spline)]
        elseif #all_spline > 0 then
            spline_id = all_spline[math.random(#all_spline)]
        end
    end
    if spline_id > 0 then
        self._spline_cd[spline_id] = { cd = 10 }
    end
    if life_time == 0 and spline_id > 0 and info.speed > 0 then
        life_time = spline_data[spline_id].length / info.speed
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    local fid = self:new_fish_id()
    local new_info = {
        id = fid,
        fish_id = info.fish_id,
        spline_id = spline_id,
        group_id = gid,
        speed = info.speed,
        life_time = life_time,
        time = time,
        data = data,
        matrix_id = matrix_id,
        group_index = 0,
        offset = util.rand_offset(-data.matrix_radius, data.matrix_radius),
        rand_fish = 0,
        incount = incount,
    }
    new_fish[#new_fish+1] = new_info
    self._fish[fid] = new_info
    pool.fish[info.fish_id] = new_info
    -- util.dump(new_info)
    -- skynet_m.log(string.format("new boss %d %d.", info.fish_id, fid))
end

function timestep:update_boss(pool_info, new_fish)
    if pool_info.count < 3 then
        local rand_pool = {}
        for k, v in ipairs(pool_info.pool) do
            if not pool_info.fish[v[1].fish_id] then
                rand_pool[#rand_pool+1] = v
            end
        end
        if #rand_pool > 0 then
            local rand_info = rand_pool[math.random(#rand_pool)]
            self:new_boss(rand_info[1], rand_info[2], 0, new_fish, pool_info, true)
            pool_info.count = pool_info.count + 1
        end
    end
    if #pool_info.ready > 0 then
        for k, v in ipairs(pool_info.ready) do
            local info = v[1]
            local time = self._game_time - info.time
            self:new_boss(info, v[2], time, new_fish, pool_info)
        end
        pool_info.ready = {}
    end
end

function timestep:delete_fish(info, hit_user, delay_msg)
    self._fish[info.id] = nil
    self._koi_fish[info.id] = nil
    local pool_info = self._fish_pool[info.data.type]
    if pool_info.count and info.incount then
        pool_info.count = pool_info.count - 1
    end
    if info.data.type == fish_type.boss_fish then
        pool_info.fish[info.fish_id] = nil
    end
    if info.born_fish then
        self._born_time = fish_born.cd
    end
    if info.rand_fish > 0 then
        self._rand_fish[info.rand_fish] = self._rand_fish[info.rand_fish] - 1
    end
    local event = self._event
    if event.info and event.data then
        local data = event.data
        local skill_fish = data.skill_fish
        if skill_fish and skill_fish[info.id] then
            skill_fish[info.id] = nil
            if hit_user > 0 then
                data.hit_count = data.hit_count + 1
                if data.hit_count >= data.skill_info.hit_count then
                    data.skill_fish = nil
                    local del_count, del_msg, kill_msg = 0, "", ""
                    for k, v in pairs(skill_fish) do
                        self:delete_fish(v, 0)
                        del_count = del_count + 1
                        del_msg = del_msg .. string.pack(">I4>I4", k, v.fish_id)
                        kill_msg = kill_msg .. string.pack("<I4", k)
                    end
                    if data.fish then
                        local msg = string.pack(">I2>I4B", s_to_c.end_skill, data.fish.id, 1)
                        self:broadcast(msg)
                    end
                    skynet_m.log(string.format("End skill %d", data.rand_skill[data.skill_index]))
                    if data.skill_index < #data.rand_skill then
                        data.skill_time = data.skill_info.delay
                        data.skill_index = data.skill_index + 1
                        data.skill_info = data.skill_data.skill[data.rand_skill[data.skill_index]]
                        if data.skill_info.fish_id > 0 or data.skill_time > 0 then
                            data.skill_status = skill_status.idle
                        else
                            data.skill_status = skill_status.ready
                        end
                    else
                        data.skill_time = 0
                        data.skill_index = nil
                        data.skill_info = nil
                        data.skill_status = skill_status.done
                        event.time = event.info.duration - BOSS_EVENT_DELAY
                        if data.fish then
                            self:delete_fish(data.fish, 0)
                            del_count = del_count + 1
                            del_msg = del_msg .. string.pack(">I4>I4", data.fish.id, data.fish.fish_id)
                            kill_msg = kill_msg .. string.pack("<I4", data.fish.id)
                            data.fish = nil
                        end
                    end
                    if del_count > 0 then
                        if del_count > 100 then
                            skynet_m.log("Kill fish exceed max count.")
                        end
                        for i = del_count + 1, 100 do
                            kill_msg = kill_msg .. string.pack("<I4", 0)
                        end
                        skynet_m.send_lua(game_message, "send_kill_fish", {
                            tableid = self._room_id,
                            fish = kill_msg,
                        })
                        del_msg = string.pack(">I2>I2", s_to_c.delete_fish, del_count) .. del_msg
                        self:broadcast(del_msg, delay_msg)
                    end
                    data.skill_damage = nil
                    data.trigger_user = nil
                    data.fish_index = nil
                    data.hit_count = nil
                end
            end
        elseif data.trigger_fish and data.trigger_fish.id == info.id then
            data.trigger_fish = nil
            if hit_user > 0 then
                data.skill_status = skill_status.ready
                data.trigger_user = hit_user
            end
        end
    end
end

local normal_status = function(info)
    if not info.data.frozen_immune and info.frozen then
        return false
    end
    return true
end

function timestep:kill_fish(info, hit_user, delay_msg)
    local event = self._event
    if event.info and event.info.type == event_type.fight_boss and event.info.fish_id == info.fish_id then
        local data = event.data
        if data then
            if data.skill_status == skill_status.cast then
                local del_count, del_msg, kill_msg = 0, "", ""
                for k, v in pairs(data.skill_fish) do
                    self:delete_fish(v, 0)
                    del_count = del_count + 1
                    del_msg = del_msg .. string.pack(">I4>I4", k, v.fish_id)
                    kill_msg = kill_msg .. string.pack("<I4", k)
                end
                if del_count > 0 then
                    if del_count > 100 then
                        skynet_m.log("Kill fish exceed max count.")
                    end
                    for i = del_count + 1, 100 do
                        kill_msg = kill_msg .. string.pack("<I4", 0)
                    end
                    skynet_m.send_lua(game_message, "send_kill_fish", {
                        tableid = self._room_id,
                        fish = kill_msg,
                    })
                    del_msg = string.pack(">I2>I2", s_to_c.delete_fish, del_count) .. del_msg
                    self:broadcast(del_msg, delay_msg)
                end
                data.skill_time = 0
                data.skill_status = skill_status.done
                event.time = event.info.duration - BOSS_EVENT_DELAY
                data.fish = nil
                data.skill_fish = nil
                data.skill_damage = nil
                data.trigger_user = nil
                data.skill_index = nil
                data.skill_info = nil
                data.fish_index = nil
                data.hit_count = nil
            else
                local del_count, del_msg, kill_msg = 0, "", ""
                local trigger_fish = data.trigger_fish
                if trigger_fish then
                    self:delete_fish(trigger_fish, 0)
                    del_count = del_count + 1
                    del_msg = del_msg .. string.pack(">I4>I4", trigger_fish.id, trigger_fish.fish_id)
                    kill_msg = kill_msg .. string.pack("<I4", trigger_fish.id)
                end
                if del_count > 0 then
                    if del_count > 100 then
                        skynet_m.log("Kill fish exceed max count.")
                    end
                    for i = del_count + 1, 100 do
                        kill_msg = kill_msg .. string.pack("<I4", 0)
                    end
                    skynet_m.send_lua(game_message, "send_kill_fish", {
                        tableid = self._room_id,
                        fish = kill_msg,
                    })
                    del_msg = string.pack(">I2>I2", s_to_c.delete_fish, del_count) .. del_msg
                    self:broadcast(del_msg, delay_msg)
                end
                data.skill_time = 0
                data.skill_status = skill_status.done
                event.time = event.info.duration - BOSS_EVENT_DELAY
                data.fish = nil
                data.skill_fish = nil
                data.skill_damage = nil
                data.trigger_user = nil
                data.skill_index = nil
                data.skill_info = nil
                data.fish_index = nil
                data.hit_count = nil
            end
        end
    end
    self:delete_fish(info, hit_user, delay_msg)
end

function timestep:update()
    local now = skynet_m.now()
    local etime = (now - self._last_time) * 0.01
    self._last_time = now
    for k, v in pairs(self._spline_cd) do
        v.cd = v.cd - etime
        if v.cd <= 0 then
            self._spline_cd[k] = nil
        end
    end
    local del_count, del_msg, kill_msg = 0, "", ""
    for k, v in pairs(self._fish) do
        if normal_status(v) then
            v.time = v.time + etime
            if v.time >= v.life_time then
                self:kill_fish(v, 0)
                del_count = del_count + 1
                del_msg = del_msg .. string.pack(">I4>I4", k, v.fish_id)
                kill_msg = kill_msg .. string.pack("<I4", k)
            end
        end
    end
    local new_fish = {}
    local event = self._event
    local stop_time = false
    if event.info then
        event.time = event.time + etime
        if event.info.type == event_type.fight_boss then
            stop_time = true
            if event.time >= event.info.duration then
                if not event.data.fish then
                    -- self._game_time = event.info.time + (event.time - event.info.duration)
                    event.info = nil
                    event.time = 0
                    event.data = nil
                end
            else
                if event.data and event.data.skill_data then
                    skill_function[event.data.skill_status](self, event.data, etime, new_fish)
                end
            end
        end
    end
    local item = self._item
    local frozen, frozen_timeout = false, false
    for i = #item, 1, -1 do
        local v = item[i]
        v.time = v.time + etime
        -- NOTICE: frozen fish (v.num == 0)
        if v.item_id == item_type.frozen or v.num == 0 then
            stop_time = true
            if v.time >= FROZEN_TIME then
                table.remove(item, i)
                frozen_timeout = true
            else
                frozen = true
            end
        end
    end
    if frozen_timeout and not frozen then
        for k, v in pairs(self._fish) do
            v.frozen = nil
        end
    end
    if not stop_time then
        self._game_time = self._game_time + etime
    end
    if self._game_time >= loop_time then
        self._game_time = self._game_time - loop_time
        self:loop()
    end
    while event.index <= #event_data do
        local info = event_data[event.index]
        if self._game_time < info.time then
            break
        end
        event_function[info.type](self, info)
        event.index = event.index + 1
    end
    self:update_fish(etime, self._fish_pool[fish_type.small_fish], new_fish)
    self:update_fish(etime, self._fish_pool[fish_type.big_fish], new_fish, true)
    self:update_boss(self._fish_pool[fish_type.boss_fish], new_fish)
    self:update_spline(new_fish)
    if self._born_time > 0 then
        self._born_time = self._born_time - etime
        if self._born_time <= 0 then
            local born_fish = fish_born.fish
            if #born_fish > 0 then
                local info = born_fish[math.random(#born_fish)]
                local num = math.random(info.rand_min, info.rand_max)
                self:new_born_fish(info, fish_data[info.fish_id], num, new_fish)
            end
            self._born_time = 0
        end
    end
    local koi_info = self._info
    if koi_info then
        if koi_info.koi_create == 1 then
            koi_info.koi_life = koi_info.koi_life - etime
            if koi_info.koi_life > 0 then
                if util.empty(self._koi_fish) then
                    for i = 1, 2 do
                        local info = fish_koi[math.random(#fish_koi)]
                        self:new_koi_fish(info, fish_data[info.fish_id], 1, new_fish)
                    end
                end
            else
                koi_info.koi_create = 0
                koi_info.koi_wait = koi_info.koi_wait + koi_info.koi_life
                koi_info.koi_life = 0
                for k, v in pairs(self._koi_fish) do
                    self:kill_fish(v, 0)
                    del_count = del_count + 1
                    del_msg = del_msg .. string.pack(">I4>I4", k, v.fish_id)
                    kill_msg = kill_msg .. string.pack("<I4", k)
                end
            end
        else
            if koi_info.koi_wait > 0 then
                koi_info.koi_wait = koi_info.koi_wait - etime
                if koi_info.koi_wait < 0 then
                    koi_info.koi_wait = 0
                end
            end
        end
    end
    if del_count > 0 then
        if del_count > 100 then
            skynet_m.log("Kill fish exceed max count.")
        end
        for i = del_count + 1, 100 do
            kill_msg = kill_msg .. string.pack("<I4", 0)
        end
        skynet_m.send_lua(game_message, "send_kill_fish", {
            tableid = self._room_id,
            fish = kill_msg,
        })
        del_msg = string.pack(">I2>I2", s_to_c.delete_fish, del_count) .. del_msg
        self:broadcast(del_msg)
    end
    local new_num = #new_fish
    if new_num > 0 then
        local new_msg = ""
        local client_msg = string.pack(">I2>I2", s_to_c.new_fish, new_num)
        local event_target = 0
        if event.info and event.info.type == event_type.fight_boss and event.info.fish_id > 0
                and not event.data.fish then
            event_target = event.info.fish_id
        end
        for k, v in ipairs(new_fish) do
            if v.fish_id == event_target then
                event.data.fish = v
            end
            -- NOTICE: define fish type with game server
            new_msg = new_msg .. string.pack("<I4<I2<I2", v.id, self:get_fish_kind(v),
                                                math.ceil(v.life_time - v.time + 10))
            client_msg = client_msg .. string.pack(">I4>I4>I4>I4>f>f>I4>I2>fB", v.id, v.fish_id, v.spline_id,
                                                    v.group_id, v.speed, v.time, v.matrix_id, v.group_index, v.offset,
                                                    v.rand_fish)
        end
        self:broadcast(client_msg)
        for i = new_num + 1, 100 do
            new_msg = new_msg .. string.pack("<I4<I2<I2", 0, 0, 0)
        end
        skynet_m.send_lua(game_message, "send_build_fish", {
            tableid = self._room_id,
            fish = new_msg,
        })
    end
end

function timestep:get_fish_kind(info)
    if info.rand_fish > 0 then
        return define.rand_fish_kind
    else
        local koi_info = self._info
        if koi_info and koi_info.rpt_mode == 1 then
            if info.data.koi_kind > 0 then
                return info.data.koi_kind
            else
                return info.data.kind
            end
        else
            return info.data.kind
        end
    end
end

function timestep:kick(user_id, agent)
    local info = self._user[user_id]
    if info and (not agent or info.agent == agent) then
        for k, v in ipairs(info.bullet) do
            self._bullet[v] = nil
        end
        self._user[user_id] = nil
        self._pos[info.pos] = nil
        self._count = self._count - 1
        if info.ready then
            self._ready_count = self._ready_count - 1
            self:broadcast(string.pack(">I2>I4", s_to_c.leave_room, user_id))
        end
        if self._count == 0 then
            self:clear()
            skynet_m.log(string.format("send clear table %d msg to game server.", self._room_id))
            skynet_m.send_lua(game_message, "send_clear", {
                tableid = self._room_id,
                flag = 0,
            })
            if game_mode == "fake_game" then
                self._info = nil
            end
        end
    end
end

function timestep:process(user_id, data)
    local info = self._user[user_id]
    if not info then
        skynet_m.log(string.format("Can't find user %d.", user_id))
        return
    end
    local cmd = string.unpack(">I2", data)
    local func = c_to_s_i[cmd]
    if func then
        self[func](self, info, data)
        info.status_time = skynet_m.now()
    else
        skynet_m.log(string.format("Receive illegal cmd %d from user %d.", cmd, user_id))
    end
end

function timestep:broadcast(msg, delay_msg)
    if delay_msg then
        self._delay_msg[#self._delay_msg+1] = msg
    else
        for _, v in pairs(self._user) do
            if v.ready then
                skynet_m.send_lua(v.agent, "send", msg)
            end
        end
    end
end

function timestep:broadcast_exclude(msg, id)
    for _, v in pairs(self._user) do
        if v.ready and v.user_id ~= id then
            skynet_m.send_lua(v.agent, "send", msg)
        end
    end
end

function timestep:delay_broadcast()
    if #self._delay_msg > 0 then
        for _, msg in ipairs(self._delay_msg) do
            for _, v in pairs(self._user) do
                if v.ready then
                    skynet_m.send_lua(v.agent, "send", msg)
                end
            end
        end
        self._delay_msg = {}
    end
end

function timestep:ready(info, data)
    skynet_m.log(string.format("User %d ready.", info.user_id))
    if info.ready then
        skynet_m.log(string.format("User %d is ready.", info.user_id))
    else
        local client_time, start_time, cannon = string.unpack(">d>f>I2", data, 3)
        info.cannon = cannon
        self:broadcast(string.pack(">I2>I4B>I2", s_to_c.join_room, info.user_id, info.pos, info.cannon))
        self._ready_count = self._ready_count + 1
        if self._ready_count == 1 then
            if start_time > 0 and self._game_time == 0 then
                self._game_time = start_time
                if self._game_time >= loop_time then
                    self._game_time = self._game_time - loop_time
                    self:loop()
                end
                local event = self._event
                while event.index <= #event_data do
                    local event_info = event_data[event.index]
                    if self._game_time < event_info.time then
                        break
                    end
                    if event_info.type ~= event_type.fight_boss then
                        event_function[event_info.type](self, event_info)
                    end
                    event.index = event.index + 1
                end
                for k, v in pairs(fish_type) do
                    self._fish_pool[v].ready = {}
                end
            end
            self:start()
        end
        info.ready = true
        local msg = string.pack(">I2>d>fB>I2", s_to_c.room_data, client_time, self._game_time, info.pos, info.cannon)
        msg = msg .. string.pack("B", self._ready_count - 1)
        for _, v in pairs(self._user) do
            if v.ready and v.user_id ~= info.user_id then
                msg = msg .. string.pack(">I4B>I2", v.user_id, v.pos, v.cannon)
            end
        end
        local koi_info = self._info
        if koi_info then
            msg = msg .. string.pack("b>i4>i4>i4b", koi_info.rpt_mode, koi_info.koi_type, math.ceil(koi_info.koi_life),
                                        math.ceil(koi_info.koi_wait), koi_info.koi_create)
        else
            msg = msg .. string.pack("b>i4>i4>i4b", 0, 0, 0, 0, 0)
        end
        local fish_msg, fish_count = "", 0
        for k, v in pairs(self._fish) do
            fish_msg = fish_msg .. string.pack(">I4>I4>I4>I4>f>f>I4>I2>fB", v.id, v.fish_id, v.spline_id, v.group_id,
                                                v.speed, v.time, v.matrix_id, v.group_index, v.offset, v.rand_fish)
            fish_count = fish_count + 1
        end
        msg = msg .. string.pack(">I2", fish_count) .. fish_msg
        local event = self._event
        if event.info then
            if event.info.type == event_type.fight_boss then
                msg = msg .. string.pack(">I4>f", event.info.id, event.info.duration - event.time)
                local edata = event.data
                if edata and edata.fish then
                    if edata.skill_status == skill_status.cast then
                        msg = msg .. string.pack(">I4>I2>I4", edata.fish.id, edata.rand_skill[edata.skill_index],
                                                    edata.trigger_user or 0)
                    else
                        msg = msg .. string.pack(">I4>I2>I4", edata.fish.id, 0, 0)
                    end
                else
                    msg = msg .. string.pack(">I4", 0)
                end
            else
                skynet_m.log(string.format("Can't get trigger event %d left time.", event.info.id))
                msg = msg .. string.pack(">I4", 0)
            end
        else
            msg = msg .. string.pack(">I4", 0)
        end
        local item_msg, item_count = "", 0
        for k, v in ipairs(self._item) do
            if v.item_id == item_type.frozen then
                item_msg = item_msg .. string.pack(">I4>I4>I4>f", v.user_id, v.item_id, v.num, FROZEN_TIME - v.time)
                item_count = item_count + 1
            else
                skynet_m.log(string.format("Can't get item %d left time.", v.item_id))
            end
        end
        msg = msg .. string.pack(">I2", item_count) .. item_msg
        skynet_m.send_lua(info.agent, "send", msg)
        skynet_m.log(string.format("Response user %d ready.", info.user_id))
    end
end

function timestep:quit(info, data)
    skynet_m.send_lua(agent_mgr, "quit", info.user_id, error_code.ok)
end

function timestep:fire(info, data)
    local num, index  = string.unpack("B", data, 3)
    for i = 1, num do
        local self_id, angle, multi, kind, rotate, target
        self_id, angle, multi, kind, rotate, target, index = string.unpack(">I4>f>I4>I4B>I4", data, index)
        if info.cannon ~= kind then
            info.cannon = kind
        end
        local bullet_id = self:new_bullet_id()
        info.bullet[self_id] = bullet_id
        skynet_m.send_lua(game_message, "send_fire", {
            tableid = self._room_id,
            seatid = info.pos - 1,
            userid = info.user_id,
            bullet = {
                id = bullet_id,
                kind = kind,
                multi = multi,
                power = 1,
                expTime = 0,
            },
        })
        self._bullet[bullet_id] = {
            id = bullet_id,
            self_id = self_id,
            kind = kind,
            angle = angle,
            multi = multi,
            rotate = rotate,
            target = target,
        }
    end
end

function timestep:is_king_fish(info)
    if info then
        local koi_info = self._info
        return koi_info and koi_info.rpt_mode == 1 and info.data.koi_kind > 0
    end
end

function timestep:hit(info, data)
    local self_id, fishid, multi = string.unpack(">I4>I4>I4", data, 3)
    local bulletid = info.bullet[self_id]
    if not bulletid then
        skynet_m.log(string.format("Can't find bullet %d when user %d hit fish %d.", self_id, info.user_id, fishid))
        return
    end
    info.bullet[self_id] = nil
    local fish_info = self._fish[fishid]
    skynet_m.send_lua(game_message, "send_catch_fish", {
        tableid = self._room_id,
        seatid = info.pos - 1,
        userid = info.user_id,
        bulletid = bulletid,
        fishid = fishid,
        bulletMulti = multi,
        fish = fish_info,
        king = self:is_king_fish(fish_info),
    })
end

function timestep:heart_beat(info, data)
    local client_time = string.unpack(">d", data, 3)
    local msg = string.pack(">I2>d>f", s_to_c.heart_beat, client_time, self._game_time)
    skynet_m.send_lua(info.agent, "send", msg)
end

function timestep:use_item(info, data)
    local item_id, item_num = string.unpack(">I4>I4", data, 3)
    if not item_id_map[item_id] then
        skynet_m.log(string.format("Can't find item %d when user %d use item.", item_id, info.user_id))
        return
    end
    skynet_m.send_lua(game_message, "send_use_prob", {
        tableid = self._room_id,
        seatid = info.pos - 1,
        userid = info.user_id,
        probid = item_id,
        probCount = item_num,
    })
end

function timestep:set_cannon(info, data)
    local cannon = string.unpack(">I2", data, 3)
    info.cannon = cannon
    local msg = string.pack(">I2B>I2", s_to_c.set_cannon, info.pos, cannon)
    self:broadcast(msg)
end

function timestep:hit_bomb(info, data)
    local self_id, fishid, multi, index = string.unpack(">I4>I4>I4", data, 3)
    local bulletid = info.bullet[self_id]
    if not bulletid then
        skynet_m.log(string.format("Can't find bullet %d when user %d hit bomb fish %d.",
                                    self_id, info.user_id, fishid))
        return
    end
    -- local bomb_fish = self._fish[fishid]
    -- if not bomb_fish or not define.bomb_fish[bomb_fish.fish_id] then
    --     skynet_m.log(string.format("Illegal bomb fish %d.", fishid))
    --     return
    -- end
    info.bullet[self_id] = nil
    local num
    num, index = string.unpack(">I2", data, index)
    if num > 99 then
        num = 99
    end
    local msg = string.pack("<I4", fishid)
    local count = 1
    for i = 1, num do
        local fish_id
        fish_id, index = string.unpack(">I4", data, index)
        msg = msg .. string.pack("<I4", fish_id)
        count = count + 1
    end
    for i = count + 1, 100 do
        msg = msg .. string.pack("<I4", 0)
    end
    skynet_m.send_lua(game_message, "send_bomb_fish", {
        tableid = self._room_id,
        seatid = info.pos - 1,
        userid = info.user_id,
        bulletid = bulletid,
        bulletMulti = multi,
        fish = msg,
        bomb_fish = self._fish[fishid],
    })
end

function timestep:hit_trigger(info, data)
    local self_id, fishid, multi, index = string.unpack(">I4>I4>I4", data, 3)
    local bulletid = info.bullet[self_id]
    if not bulletid then
        skynet_m.log(string.format("Can't find bullet %d when user %d hit trigger fish %d.",
                                    self_id, info.user_id, fishid))
        return
    end
    -- local trigger_fish = self._fish[fishid]
    -- if not trigger_fish or not util.is_trigger_fish(trigger_fish.fish_id) then
    --     if trigger_fish then
    --         skynet_m.log(string.format("Illegal trigger fish %d %d.", fishid, trigger_fish.fish_id))
    --     else
    --         skynet_m.log(string.format("Illegal trigger fish %d.", fishid))
    --     end
    --     return
    -- end
    -- skynet_m.log(string.format("hit trigger %d.", fishid))
    info.bullet[self_id] = nil
    local num
    num, index = string.unpack(">I2", data, index)
    if num > 99 then
        num = 99
    end
    local msg = string.pack("<I4", fishid)
    local count = 1
    for i = 1, num do
        local fish_id
        fish_id, index = string.unpack(">I4", data, index)
        msg = msg .. string.pack("<I4", fish_id)
        count = count + 1
    end
    for i = count + 1, 100 do
        msg = msg .. string.pack("<I4", 0)
    end
    skynet_m.send_lua(game_message, "send_trigger_fish", {
        tableid = self._room_id,
        seatid = info.pos - 1,
        userid = info.user_id,
        bulletid = bulletid,
        bulletMulti = multi,
        fish = msg,
        trigger_fish = self._fish[fishid],
    })
end

function timestep:update_damage_index(user_id, damage_index)
    local event = self._event
    if event.info then
        if event.info.type == event_type.fight_boss then
            local edata = event.data
            if edata and edata.skill_status == skill_status.cast then
                local skill_info = edata.skill_info
                if skill_info and edata.skill_damage <= skill_info.damage_count
                        and edata.skill_damage == damage_index then
                    edata.skill_damage = edata.skill_damage + 1
                    return true
                end
            end
        end
    end
end

function timestep:skill_damage(info, data)
    local damage_index, index = string.unpack("B", data, 3)
    if not self:update_damage_index(info.user_id, damage_index) then
        skynet_m.log(string.format("Illegal skill status when user %d call skill damage %d.", info.user_id,
                                    damage_index))
        return
    end
    skynet_m.log(string.format("skill damage user %d index %d.", info.user_id, damage_index))
    local num
    num, index = string.unpack(">I2", data, index)
    if num > 100 then
        num = 100
    end
    local msg = ""
    local count = 0
    for i = 1, num do
        local fish_id
        fish_id, index = string.unpack(">I4", data, index)
        msg = msg .. string.pack("<I4", fish_id)
        count = count + 1
    end
    for i = count + 1, 100 do
        msg = msg .. string.pack("<I4", 0)
    end
    skynet_m.send_lua(game_message, "send_skill_damage", {
        tableid = self._room_id,
        seatid = info.pos - 1,
        userid = info.user_id,
        fish = msg,
    })
end

function timestep:set_koi_info(info, data)
    self._info = {
        tableid = self._room_id,
        rpt_mode = 1,
    }
    local koi_info = {}
    koi_info.koi_type, koi_info.koi_life, koi_info.koi_wait, koi_info.koi_create = string.unpack(">i4>i4>i4b", data, 3)
    skynet_m.log(string.format("Table %d start koi: %d %d %d %d.", self._room_id, koi_info.koi_type, koi_info.koi_life,
                                koi_info.koi_wait, koi_info.koi_create))
    self:on_koi_info(koi_info)
end

function timestep:open_chest(info, data)
    local msg = string.pack(">I2B", s_to_c.open_chest, info.pos)
    self:broadcast_exclude(msg, info.user_id)
end

function timestep:on_fire(info)
    local binfo = info.bullet
    local bullet = self._bullet[binfo.id]
    if not bullet then
        skynet_m.log(string.format("Fire can't find bullet %d.", binfo.id))
        return
    end
    if binfo.kind ~= bullet.kind or binfo.multi ~= bullet.multi then
        skynet_m.log(string.format("Fire info is different."))
    end
    self._bullet[binfo.id] = nil
    if info.code ~= 0 then
        skynet_m.log(string.format("User %d fire bullet %d fail.", info.userid, binfo.id))
        return
    end
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Fire can't find user %d.", info.userid))
        return
    end
    user_info.cannon = binfo.kind
    local msg = string.pack(">I2>I4>I4>I4B>f>I4>I4>I8B>I4>I8", s_to_c.fire, bullet.id, bullet.self_id, binfo.kind,
                            user_info.pos, bullet.angle, binfo.multi, info.costGold, info.fishScore, bullet.rotate,
                            bullet.target, info.awardPool)
    self:broadcast(msg)
end

function timestep:on_dead(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Dead can't find user %d.", info.userid))
        return
    end
    local fish_info = self._fish[info.fishid]
    if fish_info then
        self:kill_fish(fish_info, info.userid, true)
        if fish_info.fish_id == define.frozen_fish then
            skynet_m.log("kill frozen fish.")
            local item_info = {
                item_id = info.fishid,
                num = 0,
                time = 0,
                user_id = info.userid,
            }
            self._item[#self._item+1] = item_info
            local frozen_msg = string.pack(">I2>I4>I4>I4>f", s_to_c.use_item, info.userid, info.fishid, 0,
                                            FROZEN_TIME)
            self:broadcast(frozen_msg)
            for k, v in pairs(self._fish) do
                v.frozen = true;
            end
        end
        -- NOTICE: no bullet self_id info
        local msg = string.pack(">I2B>I4>I4>I4>I2>I2>I4>I8>I8>i4", s_to_c.dead, user_info.pos, info.bulletid,
                                info.fishid, fish_info.fish_id, info.multi, info.bulletMulti, info.winGold,
                                info.fishScore, info.awardPool, info.rpt)
        self:broadcast(msg)
        self:delay_broadcast()
    else
        local msg = string.pack(">I2B>I4>I4>I4>I2>I2>I4>I8>I8>i4", s_to_c.dead, user_info.pos, info.bulletid,
                                info.fishid, 0, info.multi, info.bulletMulti, info.winGold, info.fishScore,
                                info.awardPool, info.rpt)
        self:broadcast(msg)
    end
end

function timestep:on_set_cannon(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Set cannon can't find user %d.", info.userid))
        return
    end
    user_info.cannon = info.cannon
    local msg = string.pack(">I2B>I2", s_to_c.set_cannon, user_info.pos, info.cannon)
    self:broadcast(msg)
end

function timestep:on_use_item(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Use item can't find user %d.", info.userid))
        return
    end
    local func = item_function[info.probid]
    if func then
        func(self, info)
    else
        skynet_m.log(string.format("Use item can't find item data %d.", info.probid))
        return
    end
end

function timestep:on_bomb_fish(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Bomb fish can't find user %d.", info.userid))
        return
    end
    local del_msg = ""
    for k, v in ipairs(info.fish) do
        local fish_info = self._fish[v.fishid]
        if fish_info then
            self:kill_fish(fish_info, info.userid)
            del_msg = del_msg .. string.pack(">I4>I4>I4", v.fishid, fish_info.fish_id, v.score)
        else
            del_msg = del_msg .. string.pack(">I4>I4>I4", v.fishid, 0, v.score)
        end
    end
    local msg = string.pack(">I2B>I4>I2>I4>I8>I2", s_to_c.bomb_fish, user_info.pos, info.bulletid, info.bulletMulti,
                            info.winGold, info.fishScore, #info.fish) .. del_msg
    self:broadcast(msg)
end

function timestep:on_trigger_dead(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Dead can't find user %d.", info.userid))
        return
    end
    local fish_info = self._fish[info.fishid]
    if fish_info then
        self:kill_fish(fish_info, info.userid)
        -- NOTICE: no bullet self_id info
        local msg = string.pack(">I2B>I4>I4>I4>I2", s_to_c.trigger_dead, user_info.pos, info.bulletid, info.fishid,
                                fish_info.fish_id, info.bulletMulti)
        self:broadcast(msg)
    else
        local msg = string.pack(">I2B>I4>I4>I4>I2", s_to_c.trigger_dead, user_info.pos, info.bulletid, info.fishid,
                                0, info.bulletMulti)
        self:broadcast(msg)
    end
end

function timestep:on_skill_damage(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Skill damage can't find user %d.", info.userid))
        return
    end
    local del_msg = ""
    for k, v in ipairs(info.fish) do
        local fish_info = self._fish[v.fishid]
        if fish_info then
            self:kill_fish(fish_info, info.userid)
            del_msg = del_msg .. string.pack(">I4>I4>I4", v.fishid, fish_info.fish_id, v.score)
        else
            del_msg = del_msg .. string.pack(">I4>I4>I4", v.fishid, 0, v.score)
        end
    end
    local msg = string.pack(">I2B>I4>I8>I2", s_to_c.skill_damage, user_info.pos, info.winGold, info.fishScore,
                            #info.fish) .. del_msg
    self:broadcast(msg)
end

function timestep:on_init_info(info)
    self._info = info
end

function timestep:on_koi_info(info)
    local sinfo = self._info
    sinfo.koi_type, sinfo.koi_life, sinfo.koi_wait, sinfo.koi_create
        = info.koi_type, info.koi_life, info.koi_wait, info.koi_create
    local msg = string.pack(">I2b>i4>i4>i4b", s_to_c.koi_info, sinfo.rpt_mode, sinfo.koi_type,
                            math.ceil(sinfo.koi_life), math.ceil(sinfo.koi_wait), sinfo.koi_create)
    self:broadcast(msg)
end

function timestep:on_king_dead(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("King dead can't find user %d.", info.userid))
        return
    end
    local fish_info = self._fish[info.fishid]
    if fish_info then
        self:kill_fish(fish_info, info.userid, true)
        if fish_info.fish_id == define.frozen_fish then
            skynet_m.log("kill frozen fish.")
            local item_info = {
                item_id = info.fishid,
                num = 0,
                time = 0,
                user_id = info.userid,
            }
            self._item[#self._item+1] = item_info
            local frozen_msg = string.pack(">I2>I4>I4>I4>f", s_to_c.use_item, info.userid, info.fishid, 0,
                                            FROZEN_TIME)
            self:broadcast(frozen_msg)
            for k, v in pairs(self._fish) do
                v.frozen = true;
            end
        end
        -- NOTICE: no bullet self_id info
        local msg = string.pack(">I2B>I4>I4>I4>I2>I2>I4>I8>I8>i4>i4", s_to_c.king_dead, user_info.pos, info.bulletid,
                                info.fishid, fish_info.fish_id, info.multi, info.bulletMulti, info.winGold,
                                info.fishScore, info.awardPool, info.rpt, info.rpt_ratio)
        for i = 1, 4 do
            msg = msg .. string.pack(">i4", info.fishMultis[i])
        end
        self:broadcast(msg)
        self:delay_broadcast()
    else
        local msg = string.pack(">I2B>I4>I4>I4>I2>I2>I4>I8>I8>i4>i4", s_to_c.king_dead, user_info.pos, info.bulletid,
                                info.fishid, 0, info.multi, info.bulletMulti, info.winGold, info.fishScore,
                                info.awardPool, info.rpt, info.rpt_ratio)
        for i = 1, 4 do
            msg = msg .. string.pack(">i4", info.fishMultis[i])
        end
        self:broadcast(msg)
    end
end

return {__index=timestep}