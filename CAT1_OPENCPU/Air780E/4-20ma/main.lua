-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "adcdemo"
VERSION = "1.0.0"

log.info("main", PROJECT, VERSION)

-- 一定要添加sys.lua !!!!
sys = require("sys")

-- 添加硬狗防止程序卡死
if wdt then
    wdt.init(9000) -- 初始化watchdog设置为9s
    sys.timerLoopStart(wdt.feed, 3000) -- 3s喂一次狗
end

function adc_init()
    adc.setRange(adc.ADC_RANGE_3_8) -- 启用分压, 范围0-3.8v
    adc.open(0) -- 打开ADC0
end

function adc_close()
    adc.close(0) -- 关闭ADC0
end

function get_4_20mA_value()
    local cal = adc.get(0) -- 读取ADC0的值
    if cal == nil then
        return 0
    else
        local volatge = (cal / 51) * (51 + 150)  -- 计算电压值，单位mV
        return (volatge / 500) + (volatge / ((51 + 150) * 1000))
    end
end

sys.taskInit(function()
    adc_init() -- 初始化ADC

    -- 下面是循环打印, 接地不打印0也是正常现象
    -- ADC的精度都不会太高, 若需要高精度ADC, 建议额外添加adc芯片
    while true do
        log.debug("main, 4-20mA value =", get_4_20mA_value(), "mA")
        sys.wait(1000)
    end
    adc_close() -- 关闭ADC

end)
-- 用户代码已结束---------------------------------------------
-- 结尾总是这一句
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!
