// Realistic UniFi API responses, written from the documented / observed shapes (Integration API v1 reference; classic
// controller responses of UniFi Network 8–9). Invented MACs and addresses. One small network: a UDM Pro gateway, a
// switch on its port 9, two APs on switch ports 1 and 2, three clients (one wired on switch port 5).
import Foundation

enum UniFiFixtures {
    static let gw = "74:ac:b9:00:00:01", sw = "74:ac:b9:00:00:02", ap1 = "74:ac:b9:00:00:03", ap2 = "74:ac:b9:00:00:04"

    // MARK: Integration API

    static let intSites = """
    {"offset":0,"limit":25,"count":1,"totalCount":1,"data":[{"id":"88f7af54-98f8-306a-a1c7-c9349722b1f6","internalReference":"default","name":"Default"}]}
    """
    static let intDevices = """
    {"offset":0,"limit":200,"count":3,"totalCount":3,"data":[
     {"id":"d-gw","name":"Dream Machine","model":"UDM Pro","macAddress":"74:AC:B9:00:00:01","ipAddress":"192.168.1.1","state":"ONLINE","features":["switching"],"interfaces":["ports"]},
     {"id":"d-sw","name":"Office Switch","model":"USW Pro 24 PoE","macAddress":"74:ac:b9:00:00:02","ipAddress":"192.168.1.2","state":"ONLINE","features":["switching"],"interfaces":["ports"]},
     {"id":"d-ap1","name":"Living Room AP","model":"U6 Pro","macAddress":"74:ac:b9:00:00:03","ipAddress":"192.168.1.3","state":"OFFLINE","features":["accessPoint"],"interfaces":["ports","radios"]}
    ]}
    """
    static let intDeviceDetailAP = """
    {"id":"d-ap1","name":"Living Room AP","model":"U6 Pro","supported":true,"macAddress":"74:ac:b9:00:00:03","ipAddress":"192.168.1.3",
     "state":"ONLINE","firmwareVersion":"6.6.77","firmwareUpdatable":false,"adoptedAt":"2024-03-01T10:00:00Z",
     "uplink":{"deviceId":"d-sw"},"features":{"accessPoint":{}},
     "interfaces":{"ports":[{"idx":1,"state":"UP","connector":"RJ45","maxSpeedMbps":1000,"speedMbps":1000,
       "poe":{"standard":"802.3at","type":2,"enabled":true,"state":"UP"}}],
      "radios":[{"wlanStandard":"802.11ax","frequencyGHz":2.4,"channelWidthMHz":20,"channel":6},
                {"wlanStandard":"802.11ax","frequencyGHz":5,"channelWidthMHz":80,"channel":36}]}}
    """
    static let intStatsAP = """
    {"uptimeSec":86400,"lastHeartbeatAt":"2024-03-02T10:00:00Z","loadAverage1Min":0.3,"cpuUtilizationPct":12.5,
     "memoryUtilizationPct":41.0,"uplink":{"txRateBps":8000000,"rxRateBps":16000000},
     "interfaces":{"radios":[{"frequencyGHz":5,"txRetriesPct":3.2}]}}
    """
    static let intClients = """
    {"offset":0,"limit":200,"count":3,"totalCount":3,"data":[
     {"type":"WIRELESS","id":"c-1","name":"Pixel","connectedAt":"2024-03-02T09:00:00Z","ipAddress":"192.168.1.50","macAddress":"aa:bb:cc:00:00:01","uplinkDeviceId":"d-ap1","access":{"type":"DEFAULT"}},
     {"type":"WIRED","id":"c-2","name":"NAS","ipAddress":"192.168.1.20","macAddress":"aa:bb:cc:00:00:02","uplinkDeviceId":"d-sw","access":{"type":"DEFAULT"}},
     {"type":"VPN","id":"c-3","name":"Road warrior","macAddress":"aa:bb:cc:00:00:03"}
    ]}
    """

    // MARK: Classic API

    static let classicSites = """
    {"meta":{"rc":"ok"},"data":[{"_id":"5f0000000000000000000001","name":"default","desc":"Default","role":"admin"}]}
    """
    static let statDevice = """
    {"meta":{"rc":"ok"},"data":[
     {"_id":"g1","mac":"74:ac:b9:00:00:01","type":"udm","model":"UDMPRO","model_name":"UDM Pro","name":"Dream Machine","ip":"203.0.113.7",
      "version":"4.0.6.6754","uptime":1209600,"state":1,"system-stats":{"cpu":"9.8","mem":"62.1","uptime":"1209600"},
      "temperatures":[{"name":"CPU","type":"cpu","value":61.5},{"name":"Local","type":"board","value":48}],
      "uplink":{"type":"wire","speed":1000,"full_duplex":true,"rx_bytes-r":2500000,"tx_bytes-r":300000,"port_idx":9},
      "port_table":[{"port_idx":8,"name":"Port 8","up":false,"speed":0},{"port_idx":9,"name":"WAN","up":true,"speed":1000,"full_duplex":true,"is_uplink":true}]},
     {"_id":"s1","mac":"74:ac:b9:00:00:02","type":"usw","model":"US24PRO","name":"Office Switch","ip":"192.168.1.2","version":"7.1.26",
      "uptime":"600000","state":1,"general_temperature":44,"has_temperature":true,"num_sta":4,
      "uplink":{"uplink_mac":"74:ac:b9:00:00:01","uplink_remote_port":10,"port_idx":25,"speed":10000,"type":"wire"},
      "port_table":[
       {"port_idx":1,"name":"AP Living","up":true,"speed":1000,"full_duplex":true,"port_poe":true,"poe_enable":true,"poe_power":"7.42","poe_caps":7},
       {"port_idx":2,"name":"AP Office","up":true,"speed":2500,"port_poe":true,"poe_enable":true,"poe_power":"12.10","poe_caps":15},
       {"port_idx":5,"name":"NAS","up":true,"speed":1000,"poe_mode":"off","rx_bytes":123456789,"tx_bytes":987654321},
       {"port_idx":6,"up":false,"speed":100}]},
     {"_id":"a1","mac":"74:ac:b9:00:00:03","type":"uap","model":"UAP6MP","name":"Living Room AP","ip":"192.168.1.3","version":"6.6.77",
      "uptime":86400,"state":1,"num_sta":2,
      "uplink":{"uplink_mac":"74:ac:b9:00:00:02","uplink_remote_port":1,"speed":1000,"type":"wire"},
      "radio_table":[{"name":"wifi0","radio":"ng","channel":"6","ht":"20","is_11ax":true},{"name":"wifi1","radio":"na","channel":36,"ht":80,"is_11ax":true}],
      "radio_table_stats":[{"name":"wifi0","radio":"ng","channel":6,"cu_total":38,"num_sta":1,"tx_power":17},
                           {"name":"wifi1","radio":"na","channel":36,"cu_total":12,"num_sta":1,"tx_power":23}]},
     {"_id":"a2","mac":"74:ac:b9:00:00:04","type":"uap","model":"U7PG2","name":"Office AP","state":0,
      "last_uplink":{"uplink_mac":"74:ac:b9:00:00:02","uplink_remote_port":2}}
    ]}
    """
    static let statSta = """
    {"meta":{"rc":"ok"},"data":[
     {"_id":"x1","mac":"AA:BB:CC:00:00:01","hostname":"pixel-8","name":"Pixel","ip":"192.168.1.50","oui":"Google","is_wired":false,
      "ap_mac":"74:ac:b9:00:00:03","essid":"Home","signal":-58,"rssi":38,"channel":36,"radio":"na","radio_proto":"ax",
      "tx_rate":864000,"rx_rate":576000,"tx_bytes":5000000000,"rx_bytes":200000000,"tx_bytes-r":1250000.5,"rx_bytes-r":40000,"uptime":3600},
     {"_id":"x2","mac":"aa:bb:cc:00:00:02","hostname":"nas","ip":"192.168.1.20","oui":"Synology","is_wired":true,
      "sw_mac":"74:ac:b9:00:00:02","sw_port":5,"wired-tx_bytes":9000,"wired-rx_bytes":7000,"wired-tx_bytes-r":100,"wired-rx_bytes-r":50,"uptime":99999},
     {"_id":"x3","mac":"aa:bb:cc:00:00:04","hostname":"thermostat","ip":"192.168.1.60","is_wired":false,
      "ap_mac":"74:ac:b9:00:00:03","essid":"IoT","signal":-77,"channel":6,"radio":"ng","radio_proto":"ng"},
     {"_id":"x4","mac":"aa:bb:cc:00:00:05","hostname":"mystery","ip":"192.168.1.99"}
    ]}
    """
    static let statHealth = """
    {"meta":{"rc":"ok"},"data":[
     {"subsystem":"wlan","status":"ok","num_user":2,"num_ap":2},
     {"subsystem":"wan","status":"ok","wan_ip":"203.0.113.7","isp_name":"Example Fiber","gw_mac":"74:ac:b9:00:00:01",
      "rx_bytes-r":2500000,"tx_bytes-r":300000,"uptime_stats":{"WAN":{"availability":100,"latency_average":9,"uptime":1209000}}},
     {"subsystem":"www","status":"ok","latency":11,"uptime":1209500,"drops":2,"xput_up":94.5,"xput_down":912.3,
      "speedtest_status":"Success","speedtest_lastrun":1709370000,"speedtest_ping":8},
     {"subsystem":"lan","status":"warning"}
    ]}
    """
    static let loginRequired = """
    {"meta":{"rc":"error","msg":"api.err.LoginRequired"},"data":[]}
    """
}
