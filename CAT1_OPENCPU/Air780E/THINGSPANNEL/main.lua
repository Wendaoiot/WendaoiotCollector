PROJECT = "thingspanel_air780e"
VERSION = "1.0.0"
log.info("Device protocol version", PROJECT, VERSION)

-- 获取当前毫秒数（兼容性函数）
local function get_millis()
    -- 优先使用 sys.now()
    if sys and sys.now then
        return sys.now()
    -- 其次尝试 os.millis()
    elseif os and os.millis then
        return os.millis()
    -- 最后使用 os.time()*1000（精度较低）
    else
        return os.time() * 1000
    end
end

-- 加载系统模块
_G.sys = require("sys")

-- 设备固定参数（ThingsPanel配置）
local DEVICE_CODE = "th110011"  -- 设备编号（与ThingsPanel中创建的设备编码一致）
local DEVICE_TOKEN = "d2fc5e0" -- 设备接入令牌（ThingsPanel中设备的token）
local IMEI = mobile.imei()      -- 动态获取IMEI（用于客户端ID）

-- 配置参数
local config = {
    ri = 5,        -- 传感器读取间隔（秒）
    pi = 10        -- 数据上报间隔（秒）
}

-- 传感器数据
local sensor_data = {
    temperature = 0.00,
    humidity = 0.00,
    valid = false,
    error_count = 0,
    modbus_failed = 0  -- Modbus失败计数
}

-- 全局标志位
local mqtt_connected = false  -- MQTT连接状态
local modbus_task_running = false  -- Modbus任务运行标志

-- MQTT参数（ThingsPanel平台）
local mqtt_host = "47.115.210.16"  -- ThingsPanel默认MQTT服务器
local mqtt_port = 1883                  -- 非加密端口（加密用8883）
local mqtt_isssl = false
local client_id = IMEI or DEVICE_CODE   -- 客户端ID：优先用IMEI，确保唯一
local user_name = "2bc2c547-341e-ddbf-a73"                    -- ThingsPanel通常无需用户名
local password = DEVICE_TOKEN           -- 用设备token作为密码
local pub_topic = "devices/telemetry"   -- 平台要求的上报主题
local sub_topic = "devices/telemetry/control/773e3892-c744-9412-01dd-6aad3c98e03d"     -- 平台要求的订阅主题
local mqttc = nil

-- 通信参数
local HEARTBEAT_INTERVAL = 30000   -- 心跳间隔（毫秒）
local RS485_READ_TIMEOUT = 500     -- RS485读取超时（毫秒）
local MODBUS_RETRY_TIMES = 2       -- Modbus请求重试次数

-- 串口引脚定义（保留原有配置）
local RS485_UART_ID = 2

-- 初始化SIM卡
mobile.simid(2, true)

-- 初始化RS485串口（保留原有配置）
log.info("Initializing RS485 UART...")
local rs485_result = uart.setup(
    RS485_UART_ID, 
    115200, 
    8, 
    1, 
    uart.NONE
)
log.info("RS485 UART setup result:", rs485_result)

-- 设置串口错误回调
uart.on(RS485_UART_ID, "error", function(id, err)
    log.error("uart", "RS485错误:", err)
    sensor_data.modbus_failed = sensor_data.modbus_failed + 1
end)

-- 构建ThingsPanel格式消息（修改属性上报逻辑，拆分字段，去掉last_report_time）
local function build_message(data_type, data)
    -- 设备状态上报（在线/离线）
    if data_type == "status" then
        return {
            device_code = DEVICE_CODE,
            status = data.online and "online" or "offline"
        }
    -- 属性数据上报（温湿度等拆分为平级字段，去掉last_report_time）
    elseif data_type == "attributes" then
        local msg = {
            device_code = DEVICE_CODE,
            temperature = data.temperature,   -- 拆分出温度字段
            humidity = data.humidity,         -- 拆分出湿度字段
            signal_strength = data.signal or 0,  -- 信号强度字段
            error_count = data.error_count or 0,  -- 错误计数字段
            modbus_failed = data.modbus_failed or 0 -- Modbus失败计数字段
        }
        return msg
    -- 配置响应消息
    elseif data_type == "config_ack" then
        return {
            device_code = DEVICE_CODE,
            command_ack = {
                id = data.cmd_id,
                success = data.success,
                message = data.message or ""
            }
        }
    end
end

-- 使用兼容的get_millis()替代直接调用sys.now()或os.millis()
local function send_modbus_request(request, timeout_ms)
    uart.read(RS485_UART_ID, 9)  -- 清空接收缓冲区
    
    uart.write(RS485_UART_ID, request)
    log.info("modbus", "发送请求:", request:toHex())
    
    local response = ""
    local start_time = get_millis()  -- 使用兼容函数
    local deadline = start_time + timeout_ms
    
    while get_millis() < deadline do  -- 使用兼容函数
        local recv = uart.read(RS485_UART_ID,1)
        if recv == "\x01" then
            log.info("modbus", "获取到包头")
            response = recv
            recv = uart.read(RS485_UART_ID,8)
            
            if recv and type(recv) == "string" and #recv > 0 then
                response = response .. recv
                log.info("modbus", "收到部分数据:", recv:toHex(), "长度:", #recv)
                
                if #response >= 7 then
                    log.info("modbus", "收到完整响应:", response:toHex())
                    break
                end
            elseif recv and type(recv) == "number" then
                log.error("modbus", "串口读取错误，错误码:", recv)
                break
            end
        end
    end
    
    if #response > 0 then
        return response
    else
        log.warn("modbus", "请求超时，未收到响应")
        return nil
    end
end

-- 保留原有Modbus解析函数
local function parse_modbus_response(response)
    if not response or #response < 7 then
        log.warn("modbus", "响应数据长度不足，长度: " .. (#response or 0))
        return nil, nil
    end
    
    local hex_response = response:toHex()
    log.info("modbus", "原始响应数据:", hex_response)
    
    if string.byte(response, 1) ~= 0x01 then
        log.warn("modbus", "响应地址不匹配，期望0x01，实际: " .. string.format("%02X", string.byte(response, 1)))
        return nil, nil
    end
    
    if string.byte(response, 2) ~= 0x03 then
        log.warn("modbus", "功能码不匹配，期望0x03，实际: " .. string.format("%02X", string.byte(response, 2)))
        return nil, nil
    end
    
    local byte_count = string.byte(response, 3)
    if byte_count ~= 4 then
        log.warn("modbus", "响应字节数异常，期望4，实际: " .. byte_count)
        return nil, nil
    end
    
    local temp_high = string.byte(response, 4)
    local temp_low = string.byte(response, 5)
    local humi_high = string.byte(response, 6)
    local humi_low = string.byte(response, 7)
    
    local temp_raw = (temp_high * 256 + temp_low) / 100
    local humi_raw = (humi_high * 256 + humi_low) / 100
    local temperature = math.floor(temp_raw * 100 + 0.5) / 100
    local humidity = math.floor(humi_raw * 100 + 0.5) / 100
    
    -- 数据范围校验
    if temperature < -40 or temperature > 125 then
        log.warn("modbus", "温度值超出范围: " .. temperature)
        temperature = nil
    end
    if humidity < 0 or humidity > 100 then
        log.warn("modbus", "湿度值超出范围: " .. humidity)
        humidity = nil
    end
    
    return temperature, humidity
end

-- 读取温湿度数据
local function read_temp_humidity_task()
    if modbus_task_running then 
        log.warn("modbus", "任务已在运行中，跳过")
        return 
    end
    
    modbus_task_running = true
    local task_success, task_err = pcall(function()
        log.info("modbus", "开始读取温湿度数据")
        
        local request = "\x01\x03\x20\x01\x00\x02\x9e\x0b"  -- Modbus请求帧
        log.info("modbus", "发送请求:", request:toHex())
        
        local response = nil
        local retry_count = 0
        
        while retry_count <= MODBUS_RETRY_TIMES do
            response = send_modbus_request(request, RS485_READ_TIMEOUT)
            if response and #response >= 7 then
                break
            end
            retry_count = retry_count + 1
            log.warn("modbus", "读取失败，正在重试（第" .. retry_count .. "次），超时时间: " .. RS485_READ_TIMEOUT .. "ms")
        end
        
        if response and #response >= 7 then
            local temperature, humidity = parse_modbus_response(response)
            if temperature and humidity then
                sensor_data.temperature = temperature
                sensor_data.humidity = humidity
                sensor_data.valid = true
                sensor_data.error_count = 0
                sensor_data.modbus_failed = 0
                log.info("modbus", "解析成功: 温度=" .. sensor_data.temperature .. "℃, 湿度=" .. sensor_data.humidity .. "%RH")
                
                -- 上报数据到ThingsPanel
                if mqtt_connected then
                    local signal = mobile.rssi() + 100  -- 计算信号强度（0-100）
                    signal = math.max(0, math.min(100, signal))
                    
                    local attr_data = {
                        temperature = sensor_data.temperature,
                        humidity = sensor_data.humidity,
                        signal = signal,
                        error_count = sensor_data.error_count,
                        modbus_failed = sensor_data.modbus_failed
                    }
                    local msg = build_message("attributes", attr_data)
                    sys.publish("mqtt_pub", pub_topic, json.encode(msg))
                    log.info("mqtt", "已发布温湿度等拆分字段数据（无last_report_time）")
                end
            else
                sensor_data.modbus_failed = sensor_data.modbus_failed + 1
                log.warn("modbus", "数据解析失败，失败计数: " .. sensor_data.modbus_failed)
            end
        else
            sensor_data.modbus_failed = sensor_data.modbus_failed + 1
            log.warn("modbus", "所有重试均失败，总失败计数: " .. sensor_data.modbus_failed)
        end
    end)
    
    modbus_task_running = false
    
    if not task_success then
        log.error("modbus", "任务执行出错", task_err)
        sensor_data.modbus_failed = sensor_data.modbus_failed + 1
    end
end

-- 处理ThingsPanel下发命令
local function handle_command(cmd)
    if not cmd.id or not cmd.command then
        log.warn("command", "无效命令格式")
        return false, "invalid command format"
    end
    
    -- 配置上报/读取间隔
    if cmd.command == "set_intervals" then
        local ri = cmd.params.ri
        local pi = cmd.params.pi
        
        local success = true
        local msg = ""
        
        -- 验证并更新读取间隔（ri）
        if ri and type(ri) == "number" and ri >= 5 then
            config.ri = ri
            sys.timerStop("modbus_task")
            sys.timerLoopStart(read_temp_humidity_task, config.ri * 1000, "modbus_task")
            msg = msg .. "读取间隔更新为" .. ri .. "秒; "
        elseif ri then
            success = false
            msg = msg .. "无效的读取间隔（需≥5秒）; "
        end
        
        -- 验证并更新上报间隔（pi）
        if pi and type(pi) == "number" and pi >= 5 then
            config.pi = pi
            sys.timerStop("report_task")
            sys.timerLoopStart(function()
                if sensor_data.valid and mqtt_connected then
                    local signal = mobile.rssi() + 100
                    signal = math.max(0, math.min(100, signal))
                    local attr_data = {
                        temperature = sensor_data.temperature,
                        humidity = sensor_data.humidity,
                        signal = signal,
                        error_count = sensor_data.error_count,
                        modbus_failed = sensor_data.modbus_failed
                    }
                    local msg = build_message("attributes", attr_data)
                    mqttc:publish(pub_topic, json.encode(msg))
                    log.info("mqtt", "定时上报数据（无last_report_time）")
                end
            end, config.pi * 1000, "report_task")
            msg = msg .. "上报间隔更新为" .. pi .. "秒"
        elseif pi then
            success = false
            msg = msg .. "无效的上报间隔（需≥5秒）"
        end
        
        -- 回复命令确认
        local ack_msg = build_message("config_ack", {
            cmd_id = cmd.id,
            success = success,
            message = msg
        })
        sys.publish("mqtt_pub", pub_topic, json.encode(ack_msg))
        return success, msg
    else
        log.warn("command", "未知命令: " .. cmd.command)
        return false, "unknown command"
    end
end

-- 初始化MQTT连接
sys.taskInit(function()
    log.info("mqtt", "初始化MQTT连接...")
    
    mqttc = mqtt.create(nil, mqtt_host, mqtt_port, mqtt_isssl)
    mqttc:auth(client_id, user_name, password)  -- 用token认证
    mqttc:autoreconn(true, 3000)  -- 自动重连（3秒间隔）
    
    mqttc:on(function(mqtt_client, event, data, payload)
        log.info("mqtt", "事件:", event, "数据:", data)
        
        if event == "conack" then
            mqtt_connected = true
            sys.publish("mqtt_conack")
            mqtt_client:subscribe(sub_topic)  -- 订阅命令主题
            log.info("mqtt", "已订阅命令主题: " .. sub_topic)
            
            -- 上报在线状态
            local status_msg = build_message("status", {online = true})
            mqttc:publish(pub_topic, json.encode(status_msg))
            log.info("mqtt", "已上报在线状态")
            
            -- 定时上报任务
            sys.timerLoopStart(function()
                if sensor_data.valid and mqtt_connected then
                    local signal = mobile.rssi() + 100
                    signal = math.max(0, math.min(100, signal))
                    local attr_data = {
                        temperature = sensor_data.temperature,
                        humidity = sensor_data.humidity,
                        signal = signal,
                        error_count = sensor_data.error_count,
                        modbus_failed = sensor_data.modbus_failed
                    }
                    local msg = build_message("attributes", attr_data)
                    mqttc:publish(pub_topic, json.encode(msg))
                    log.info("mqtt", "定时上报数据（无last_report_time）")
                end
            end, config.pi * 1000, "report_task")
            
            -- 定时读取任务
            sys.timerLoopStart(read_temp_humidity_task, config.ri * 1000, "modbus_task")
            log.info("mqtt", "已启动定时任务（读取间隔:" .. config.ri .. "s, 上报间隔:" .. config.pi .. "s）")
            
        elseif event == "recv" then
            -- 处理下行命令
            local payload_str = tostring(payload)
            log.info("mqtt", "收到下行命令: " .. payload_str)
            
            local cmd = json.decode(payload_str)
            if cmd and cmd.device_code == DEVICE_CODE then
                handle_command(cmd)
            else
                log.warn("mqtt", "命令格式错误或设备编码不匹配")
            end
            
        elseif event == "disconn" then
            mqtt_connected = false
            log.warn("mqtt", "连接断开，等待自动重连...")
            -- 上报离线状态
            local status_msg = build_message("status", {online = false})
            mqttc:publish(pub_topic, json.encode(status_msg))
            
        elseif event == "reconn" then
            mqtt_connected = true
            log.info("mqtt", "重新连接成功")
            -- 重连后上报在线状态
            local status_msg = build_message("status", {online = true})
            mqttc:publish(pub_topic, json.encode(status_msg))
        end
    end)
    
    log.info("mqtt", "连接到ThingsPanel MQTT服务器...")
    mqttc:connect()
    
    -- 等待连接成功（超时30秒）
    local ret = sys.waitUntil("mqtt_conack", 30000)
    if not ret then
        log.error("mqtt", "连接超时，将持续重试")
    end
    
    -- MQTT消息发布循环
    while true do
        local ret, topic, data = sys.waitUntil("mqtt_pub", config.ri * 1000)
        if ret then
            if topic == "close" then 
                log.info("mqtt", "关闭连接")
                break 
            end
            
            if mqtt_connected and mqttc then
                mqttc:publish(topic, data)
                log.info("mqtt", "发布消息到主题: " .. topic)
            else
                log.warn("mqtt", "MQTT未连接，消息暂存")
            end
        end
    end
    
    log.info("mqtt", "关闭MQTT连接")
    if mqttc then
        mqttc:close()
        mqttc = nil
    end
end)

-- 系统监控任务
sys.taskInit(function()
    local last_check = os.time()
    
    while true do
        sys.wait(10000)  -- 每10秒检查一次
        
        local now = os.time()
        log.info("monitor", "系统运行中，已运行: " .. (now - last_check) .. "秒")
        log.info("monitor", "MQTT状态: " .. (mqtt_connected and "已连接" or "未连接"))
        log.info("monitor", "传感器状态: 温度=" .. sensor_data.temperature .. "℃, 湿度=" .. sensor_data.humidity .. "%RH")
        log.info("monitor", "Modbus失败计数: " .. sensor_data.modbus_failed)
        
        -- 检查MQTT连接
        if not mqtt_connected and mqttc then
            log.warn("monitor", "MQTT未连接，尝试重连")
            mqttc:connect()
        end
        
        last_check = now
    end
end)

-- 启动系统
log.info("system", "系统启动中...")
sys.run()    