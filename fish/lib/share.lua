local skynet_m = require "skynet_m"
local sharedata = require "skynet.sharedata"

local share = {}

skynet_m.init(function()
    -- share with all agent
    share.event_data = sharedata.query("event_data")
    share.fish_data = sharedata.query("fish_data")
    share.spline_data = sharedata.query("spline_data")
    share.message = sharedata.query("message")
    share.define = sharedata.query("define")
    share.camera_spline = sharedata.query("camera_spline")
    share.camera_boss_spline = sharedata.query("camera_boss_spline")
    share.matrix_data = sharedata.query("matrix_data")
    share.skill_data = sharedata.query("skill_data")
    share.fish_born = sharedata.query("fish_born")
    share.fish_koi = sharedata.query("fish_koi")
end)

return share
