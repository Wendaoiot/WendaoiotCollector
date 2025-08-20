

-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "base_framework"
VERSION = "1.0.0"

log.info("this the first version", PROJECT, VERSION)

-- sys库是标配
_G.sys = require("sys")

if wdt then
    --添加硬狗防止程序卡死，在支持的设备上启用这个功能
    wdt.init(9000)--初始化watchdog设置为9s
    sys.timerLoopStart(wdt.feed, 3000)--3s喂一次狗
end


------------标志------------------
enter_mode=0  -- 全局标志	0:工作模式，1:配置模式

---------------------------------------

-- -- 先初始化需要的设备
-- pm.wake("WAKE")
-- pin.setup(23,1)
-- -- 初始化SIM卡
mobile.simid(2,true)--优先用SIM0

-- 初始化KV数据库
if fdb.kvdb_init("env", "onchip_fdb") then
    log.info("fdb", "kv数据库初始化成功")
end

-- 检查配置
if fdb.kv_get("isConfig") == 0 then
    enter_mode = 1
end

-- 初始化串口

-- 主循环
while 1 do 
	-- 检查有没有AT指令		
	
	if enter_mode == 1 then
		
	else
		
	end
end


-- 初始化TTL串口1
uartid_1 = 1 -- 根据实际设备选取不同的uartid
uartid_2 = 2 -- 根据实际设备选取不同的uartid
log.info("uart_exist: ", uart.exist(uartid_1))
log.info("uart_exist: ", uart.exist(uartid_2))

local result = uart.setup(
    uartid_1,--串口id
    115200,--波特率
    8,--数据位
    1,--停止位
    uart.NONE
)
local result = uart.setup(
    uartid_2,--串口id
    115200,--波特率
    8,--数据位
    1,--停止位
    uart.NONE
)
-----配置串口工作模式的切换
uart.on(uartid_1, "receive", function(id, len)
    local tmp_data = ""
    local mqttdata_flag=0
    --这里是配置模式的串口
    if enter_mode==1 and config_flag==1 then 
        while 1 do 
            local tmp = uart.read(uartid_1)
            if not tmp or #tmp == 0 then
                break
            elseif string.sub(tmp, 1, 2)=="AT" then
                config_data=tmp  ---赋值给配置数据传到下面的配置函数
                print(config_data)
            else 
                print("nil")
            end
        end
    else  ------这里是工作模式的串口
        while 1 do 
            local tmp = uart.read(uartid_1)
            if not tmp or #tmp == 0 then
                break
            elseif tmp=="+++" and config_flag==0 and config_flag_NO==0 then
                enter_mode=1
                config_flag=1
                break
            end
            tmp_data = tmp_data .. tmp --Lua中的字符串连接操作
            mqttdata_flag=1
        end
        if mqttdata_flag==1 then 
            log.info("uart", "uart1收到数据长度", #tmp_data)
            sys.publish("mqtt_pub", pub_topic, tmp_data)
            mqttdata_flag=0
        end
    end

end)

-----配置串口工作模式的切换
uart.on(uartid_2, "receive", function(id, len)
    local tmp_data = ""
    local mqttdata_flag=0
    --这里是配置模式的串口
    if enter_mode==1 and config_flag==1 then 
        while 1 do 
            local tmp = uart.read(uartid_2)
            if not tmp or #tmp == 0 then
                break
            elseif string.sub(tmp, 1, 2)=="AT" then
                config_data=tmp  ---赋值给配置数据传到下面的配置函数
                print(config_data)
            else 
                print("nil")
            end
        end
    else  ------这里是工作模式的串口
        while 1 do 
            local tmp = uart.read(uartid_2)
            if not tmp or #tmp == 0 then
                break
            elseif tmp=="+++" and config_flag==0 and config_flag_NO==0 then
                enter_mode=1
                config_flag=1
                break
            end
            tmp_data = tmp_data .. tmp --Lua中的字符串连接操作
            mqttdata_flag=1
        end
        if mqttdata_flag==1 then 
            log.info("uart", "uart2收到数据长度", #tmp_data)
            sys.publish("mqtt_pub", pub_topic, tmp_data)
            mqttdata_flag=0
        end
    end

end)
-- ----初始化MQTT
sys.taskInit(function()
    sys.waitUntil("start_mqtt")
    if rtos.bsp() == "EC618" then
        -- Air780E/Air600E系列
        --mobile.simid(2) -- 自动切换SIM卡
        -- LED = gpio.setup(27, 0, gpio.PULLUP)
        device_id = mobile.imei()
        sys.waitUntil("IP_READY", 30000)
        --pub_topic = "/luatos/pub/" .. (mobile.imei())
        --sub_topic = "/luatos/sub/" .. (mobile.imei())
        client_id = mobile.imei()
    end
    -- 打印一下上报(pub)和下发(sub)的topic名称
    -- 上报: 设备 ---> 服务器
    -- 下发: 设备 <--- 服务器
    -- 可使用mqtt.x等客户端进行调试
    log.info("mqtt", "pub", pub_topic)
    log.info("mqtt", "sub", sub_topic)

     -- 打印一下支持的加密套件, 通常来说, 固件已包含常见的99%的加密套件
    -- if crypto.cipher_suites then
    --     log.info("cipher", "suites", json.encode(crypto.cipher_suites()))
    -- end

    -------------------------------------
    -------- MQTT 演示代码 --------------
    -------------------------------------

    mqttc = mqtt.create(nil,mqtt_host, mqtt_port, mqtt_isssl, ca_file)
    ---mqtt三元组配置及cleanSession,cleanSession可选
    print(client_id,user_name,password)
    mqttc:auth(client_id,user_name,password) -- client_id必填,其余选填
    -- mqttc:keepalive(240) -- 默认值240s
    mqttc:autoreconn(true, 3000) -- 自动重连机制

    mqttc:on(function(mqtt_client, event, data, payload)
        -- 用户自定义代码
        log.info("mqtt", "event", event, mqtt_client, data, payload)
    ---conack -- 服务器鉴权完成,mqtt连接已经建立, 可以订阅和发布数据了,没有附加数据
        if event == "conack" then
            sys.publish("mqtt_conack")
            mqtt_client:subscribe(sub_topic)--单主题订阅
            -- mqtt_client:subscribe({[topic1]=1,[topic2]=1,[topic3]=1})--多主题订阅
        --- recv  -- 接收到数据,由服务器下发, data为topic值(string), payload为业务数据(string).metas是元数据(table), 一般不处理
        elseif event == "recv" then
            log.info("mqtt", "downlink", "topic", data, "payload", payload)
            sys.publish("mqtt_payload", data, payload)
        --sent   -- 发送完成, qos0会马上通知, qos1/qos2会在服务器应答会回调, data为消息id
        elseif event == "sent" then
            log.info("mqtt", "sent", "pkgid", data)
        -- elseif event == "disconnect" then
            -- 非自动重连时,按需重启mqttc
            -- mqtt_client:connect()
        end
		
		print("IN SLEEP!")
		pm.power(pm.USB, false) 
		pm.request(pm.LIGHT)
    end)

    mqttc:connect()
    sys.waitUntil("mqtt_conack")---如果没连接成功阻塞在这里,3s后自动重连
    while true do
        -- mqttc自动处理重连  接受串口数据的publish
        local ret, topic, data, qos = sys.waitUntil("mqtt_pub", 300000)
        if ret then
            if topic == "close" then break end
            mqttc:publish(topic, data, qos)
        end
    end
    mqttc:close()
    mqttc = nil

end)
-- -----这里接受MQTT传下来的数据，然后传到uart1
sys.subscribe("mqtt_payload", function(topic, payload)
    log.info("uart", "uart发送数据长度", #payload)
    uart.write(uartid_1, topic)
    uart.write(uartid_1, payload)
	uart.write(uartid_2, topic)
    uart.write(uartid_2, payload)
end)

local loopId2=0
-- ------初始化配置模式
function AT_mode()
    print("您已进入配置模式，请根据提示操作！注意后面没有换行符号")
    print("1.MQTT服务器地址(域名或IP)-->  AT+MQTTIP=IP地址")
    print("2.MQTT服务器账号-->  AT+MQTTZH=账号")
    print("3.MQTT服务器密码-->  AT+MQTTMM=密码")
    print("4.上报的TOPIC-->     AT+TOPUP=从机发布的主题")
    print("5.下行的TOPIC-->     AT+TOPDOWN=从机订阅的主题")
    print("6.退出配置模式-->     AT+FINISH")
        loopId2 =sys.timerLoopStart(function()
        local data_len=0
        local start_flag=0
        local end_flag=0 --and data_len==2
        
        if config_data ~="" then
            data_len=string.len(config_data)
            --print(data_len)
            start_flag,end_flag=string.find(config_data, "=")
           -- print(end_flag)
            if config_data=="AT"  then
                config_data="" 
                print("OK")
            elseif data_len>2 then
                if end_flag~=nil then
                    select_data=string.sub(config_data,1,end_flag-1)
                    --print("select_data",select_data)
                end
                if select_data=="AT+MQTTIP" then
                    mqtt_host=string.sub(config_data,end_flag+1,data_len)
                    select_data=""
                    config_data=""  
                    print(mqtt_host)
                    print("IP 已配置")        
                elseif select_data=="AT+MQTTZH" then
                    user_name=string.sub(config_data,end_flag+1,data_len)
                    select_data=""
                    config_data=""  
                    --print(user_name)
                    print("账号 已配置")  
                elseif select_data=="AT+MQTTMM" then
                    password=string.sub(config_data,end_flag+1,data_len)
                    select_data=""
                    config_data="" 
                    --print(password) 
                    print("密码 已配置")  
                elseif select_data== "AT+TOPUP" then
                    pub_topic=string.sub(config_data,end_flag+1,data_len)
                    select_data=""
                    config_data="" 
                   -- print(pub_topic)
                    print("发布主题的配置")  
                elseif select_data=="AT+TOPDOWN" then
                    sub_topic=string.sub(config_data,end_flag+1,data_len)
                    select_data=""
                    config_data="" 
                    --print(sub_topic) 
                    print("订阅主题已配置")
                 
                elseif config_data== "AT+FINISH" then
                    enter_mode=0  --串口里不能进入配置模式了
                    print("退出配置模式,进入工作模式。")
                    print("正在初始化mqtt,请等待一会。")
                    enter_mode=2
                    sys.publish("start_mqtt")
                    sys.timerStop(loopId2)
                else 
                -- print("请按提示正确输入！！！")
                end
            end
        end
        --print("TEST")
    end,500)
end



------开机倒数定时器
local loopId = sys.timerLoopStart(function()
    n=n-1
    if enter_mode==1 then
       sys.timerStop(loopId)
    elseif n >=0 then
        print("倒计时:",n,"秒")
    else
       sys.timerStop(loopId)
       enter_mode = 2
       config_flag_NO=1
    end 
end,1000)

sys.taskInit(function()
    sys.wait(7000)
        if enter_mode == 1 then
            AT_mode()---配置模式
        elseif enter_mode==2 then
            print("here start work!")---工作模式
            sys.publish("start_mqtt")
        end
 end)
--print("test")

-- --------启动任务-----------
sys.run()