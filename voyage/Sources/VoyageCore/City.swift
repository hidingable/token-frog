import Foundation

public struct Coordinate: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    public func distanceKm(to other: Coordinate) -> Double {
        let radius = 6371.0
        let dLat = (other.lat - lat) * .pi / 180
        let dLon = (other.lon - lon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * .pi / 180) * cos(other.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(1 - a))
    }
}

public struct City: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let country: String
    public let coordinate: Coordinate
    public let wikiZh: String
    public let wikiEn: String
}

private func city(_ id: String, _ name: String, _ country: String, _ lat: Double, _ lon: Double, wiki: String? = nil, en: String) -> City {
    City(id: id, name: name, country: country, coordinate: Coordinate(lat: lat, lon: lon), wikiZh: wiki ?? name, wikiEn: en)
}

extension City {
    public static func find(_ id: String) -> City? { byId[id] }

    public static func named(_ id: String) -> City {
        guard let found = byId[id] else { preconditionFailure("Unknown city id \(id)") }
        return found
    }

    private static let byId: [String: City] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static let all: [City] = [
        city("shanghai", "上海", "中国", 31.23, 121.47, en: "Shanghai"),
        city("beijing", "北京", "中国", 39.90, 116.40, en: "Beijing"),
        city("xian", "西安", "中国", 34.34, 108.94, en: "Xi'an"),
        city("chengdu", "成都", "中国", 30.57, 104.07, en: "Chengdu"),
        city("kunming", "昆明", "中国", 25.04, 102.71, en: "Kunming"),
        city("urumqi", "乌鲁木齐", "中国", 43.83, 87.62, en: "Ürümqi"),
        city("lhasa", "拉萨", "中国", 29.65, 91.14, en: "Lhasa"),
        city("hongkong", "香港", "中国", 22.32, 114.17, en: "Hong Kong"),
        city("taipei", "台北", "台湾", 25.03, 121.57, en: "Taipei"),
        city("seoul", "首尔", "韩国", 37.57, 126.98, en: "Seoul"),
        city("busan", "釜山", "韩国", 35.18, 129.08, en: "Busan"),
        city("fukuoka", "福冈", "日本", 33.59, 130.40, wiki: "福冈市", en: "Fukuoka"),
        city("osaka", "大阪", "日本", 34.69, 135.50, wiki: "大阪市", en: "Osaka"),
        city("kyoto", "京都", "日本", 35.01, 135.77, wiki: "京都市", en: "Kyoto"),
        city("tokyo", "东京", "日本", 35.68, 139.69, en: "Tokyo"),
        city("sapporo", "札幌", "日本", 43.06, 141.35, wiki: "札幌市", en: "Sapporo"),
        city("vladivostok", "海参崴", "俄罗斯", 43.12, 131.89, en: "Vladivostok"),
        city("irkutsk", "伊尔库茨克", "俄罗斯", 52.29, 104.30, en: "Irkutsk"),
        city("moscow", "莫斯科", "俄罗斯", 55.76, 37.62, en: "Moscow"),
        city("ulaanbaatar", "乌兰巴托", "蒙古", 47.89, 106.91, en: "Ulaanbaatar"),
        city("hanoi", "河内", "越南", 21.03, 105.85, en: "Hanoi"),
        city("hochiminh", "胡志明市", "越南", 10.82, 106.63, en: "Ho Chi Minh City"),
        city("bangkok", "曼谷", "泰国", 13.76, 100.50, en: "Bangkok"),
        city("chiangmai", "清迈", "泰国", 18.79, 98.98, en: "Chiang Mai"),
        city("siemreap", "暹粒", "柬埔寨", 13.36, 103.86, wiki: "暹粒市", en: "Siem Reap"),
        city("kualalumpur", "吉隆坡", "马来西亚", 3.14, 101.69, en: "Kuala Lumpur"),
        city("singapore", "新加坡", "新加坡", 1.35, 103.82, en: "Singapore"),
        city("jakarta", "雅加达", "印度尼西亚", -6.21, 106.85, en: "Jakarta"),
        city("bali", "巴厘岛", "印度尼西亚", -8.65, 115.22, en: "Bali"),
        city("manila", "马尼拉", "菲律宾", 14.60, 120.98, en: "Manila"),
        city("yangon", "仰光", "缅甸", 16.84, 96.17, en: "Yangon"),
        city("dhaka", "达卡", "孟加拉国", 23.81, 90.41, en: "Dhaka"),
        city("kathmandu", "加德满都", "尼泊尔", 27.72, 85.32, en: "Kathmandu"),
        city("delhi", "新德里", "印度", 28.61, 77.21, en: "New Delhi"),
        city("mumbai", "孟买", "印度", 19.08, 72.88, en: "Mumbai"),
        city("colombo", "科伦坡", "斯里兰卡", 6.93, 79.86, en: "Colombo"),
        city("tashkent", "塔什干", "乌兹别克斯坦", 41.30, 69.24, en: "Tashkent"),
        city("samarkand", "撒马尔罕", "乌兹别克斯坦", 39.65, 66.96, en: "Samarkand"),
        city("almaty", "阿拉木图", "哈萨克斯坦", 43.24, 76.89, en: "Almaty"),
        city("dubai", "迪拜", "阿联酋", 25.20, 55.27, en: "Dubai"),
        city("muscat", "马斯喀特", "阿曼", 23.59, 58.41, en: "Muscat"),
        city("doha", "多哈", "卡塔尔", 25.29, 51.53, en: "Doha"),
        city("amman", "安曼", "约旦", 31.95, 35.93, en: "Amman"),
        city("istanbul", "伊斯坦布尔", "土耳其", 41.01, 28.98, en: "Istanbul"),
        city("tbilisi", "第比利斯", "格鲁吉亚", 41.72, 44.79, en: "Tbilisi"),
        city("athens", "雅典", "希腊", 37.98, 23.73, en: "Athens"),
        city("rome", "罗马", "意大利", 41.90, 12.50, en: "Rome"),
        city("venice", "威尼斯", "意大利", 45.44, 12.33, en: "Venice"),
        city("vienna", "维也纳", "奥地利", 48.21, 16.37, en: "Vienna"),
        city("prague", "布拉格", "捷克", 50.08, 14.44, en: "Prague"),
        city("berlin", "柏林", "德国", 52.52, 13.40, en: "Berlin"),
        city("zurich", "苏黎世", "瑞士", 47.38, 8.54, en: "Zurich"),
        city("paris", "巴黎", "法国", 48.86, 2.35, en: "Paris"),
        city("amsterdam", "阿姆斯特丹", "荷兰", 52.37, 4.90, en: "Amsterdam"),
        city("london", "伦敦", "英国", 51.51, -0.13, en: "London"),
        city("edinburgh", "爱丁堡", "英国", 55.95, -3.19, en: "Edinburgh"),
        city("dublin", "都柏林", "爱尔兰", 53.35, -6.26, en: "Dublin"),
        city("reykjavik", "雷克雅未克", "冰岛", 64.15, -21.94, en: "Reykjavík"),
        city("oslo", "奥斯陆", "挪威", 59.91, 10.75, en: "Oslo"),
        city("stockholm", "斯德哥尔摩", "瑞典", 59.33, 18.07, en: "Stockholm"),
        city("helsinki", "赫尔辛基", "芬兰", 60.17, 24.94, en: "Helsinki"),
        city("barcelona", "巴塞罗那", "西班牙", 41.39, 2.17, en: "Barcelona"),
        city("lisbon", "里斯本", "葡萄牙", 38.72, -9.14, en: "Lisbon"),
        city("marrakesh", "马拉喀什", "摩洛哥", 31.63, -7.99, en: "Marrakesh"),
        city("cairo", "开罗", "埃及", 30.04, 31.24, en: "Cairo"),
        city("addisababa", "亚的斯亚贝巴", "埃塞俄比亚", 9.03, 38.74, en: "Addis Ababa"),
        city("nairobi", "内罗毕", "肯尼亚", -1.29, 36.82, en: "Nairobi"),
        city("zanzibar", "桑给巴尔城", "坦桑尼亚", -6.16, 39.20, en: "Zanzibar City"),
        city("capetown", "开普敦", "南非", -33.92, 18.42, en: "Cape Town"),
        city("windhoek", "温得和克", "纳米比亚", -22.56, 17.08, en: "Windhoek"),
        city("antananarivo", "塔那那利佛", "马达加斯加", -18.88, 47.51, en: "Antananarivo"),
        city("lagos", "拉各斯", "尼日利亚", 6.52, 3.38, en: "Lagos"),
        city("accra", "阿克拉", "加纳", 5.60, -0.19, en: "Accra"),
        city("dakar", "达喀尔", "塞内加尔", 14.72, -17.47, en: "Dakar"),
        city("sydney", "悉尼", "澳大利亚", -33.87, 151.21, en: "Sydney"),
        city("melbourne", "墨尔本", "澳大利亚", -37.81, 144.96, en: "Melbourne"),
        city("perth", "珀斯", "澳大利亚", -31.95, 115.86, en: "Perth"),
        city("darwin", "达尔文", "澳大利亚", -12.46, 130.84, wiki: "达尔文市", en: "Darwin, Northern Territory"),
        city("auckland", "奥克兰", "新西兰", -36.85, 174.76, wiki: "奥克兰 (新西兰)", en: "Auckland"),
        city("queenstown", "皇后镇", "新西兰", -45.03, 168.66, en: "Queenstown, New Zealand"),
        city("suva", "苏瓦", "斐济", -18.14, 178.44, en: "Suva"),
        city("honolulu", "檀香山", "美国", 21.31, -157.86, en: "Honolulu"),
        city("anchorage", "安克雷奇", "美国", 61.22, -149.90, en: "Anchorage, Alaska"),
        city("seattle", "西雅图", "美国", 47.61, -122.33, en: "Seattle"),
        city("sanfrancisco", "旧金山", "美国", 37.77, -122.42, en: "San Francisco"),
        city("losangeles", "洛杉矶", "美国", 34.05, -118.24, en: "Los Angeles"),
        city("denver", "丹佛", "美国", 39.74, -104.99, en: "Denver"),
        city("chicago", "芝加哥", "美国", 41.88, -87.63, en: "Chicago"),
        city("neworleans", "新奥尔良", "美国", 29.95, -90.07, en: "New Orleans"),
        city("newyork", "纽约", "美国", 40.71, -74.01, wiki: "纽约市", en: "New York City"),
        city("vancouver", "温哥华", "加拿大", 49.28, -123.12, en: "Vancouver"),
        city("toronto", "多伦多", "加拿大", 43.65, -79.38, en: "Toronto"),
        city("quebec", "魁北克市", "加拿大", 46.81, -71.21, en: "Quebec City"),
        city("mexicocity", "墨西哥城", "墨西哥", 19.43, -99.13, en: "Mexico City"),
        city("havana", "哈瓦那", "古巴", 23.11, -82.37, en: "Havana"),
        city("panama", "巴拿马城", "巴拿马", 8.98, -79.52, en: "Panama City"),
        city("bogota", "波哥大", "哥伦比亚", 4.71, -74.07, en: "Bogotá"),
        city("quito", "基多", "厄瓜多尔", -0.18, -78.47, en: "Quito"),
        city("lima", "利马", "秘鲁", -12.05, -77.04, en: "Lima"),
        city("cusco", "库斯科", "秘鲁", -13.53, -71.97, en: "Cusco"),
        city("lapaz", "拉巴斯", "玻利维亚", -16.49, -68.12, en: "La Paz"),
        city("santiago", "圣地亚哥", "智利", -33.45, -70.67, wiki: "圣地亚哥 (智利)", en: "Santiago"),
        city("buenosaires", "布宜诺斯艾利斯", "阿根廷", -34.60, -58.38, en: "Buenos Aires"),
        city("ushuaia", "乌斯怀亚", "阿根廷", -54.80, -68.30, en: "Ushuaia"),
        city("montevideo", "蒙得维的亚", "乌拉圭", -34.90, -56.16, en: "Montevideo"),
        city("rio", "里约热内卢", "巴西", -22.91, -43.17, en: "Rio de Janeiro"),
        city("manaus", "马瑙斯", "巴西", -3.12, -60.02, en: "Manaus"),
    ]
}
