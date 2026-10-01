import Foundation

// MARK: - 农历与传统历法工具（零依赖，纯本地计算）
// 农历月日：系统 Calendar(identifier: .chinese)
// 24 节气：太阳视黄经 15° 整倍数时刻的天文近似算法（低精度黄经公式 + 二分迭代反求），
//          民用精度 ±15 分钟内，全年结果一次性计算并缓存
enum LunarCalendar {
    private static let lunar = Calendar(identifier: .chinese)
    
    // 农历月名（闰月由调用处加「闰」前缀）
    private static let monthNames = ["正月", "二月", "三月", "四月", "五月", "六月",
                                     "七月", "八月", "九月", "十月", "冬月", "腊月"]
    // 农历日次
    private static let dayNames = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"
    ]
    private static let heavenlyStems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    private static let earthlyBranches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
    private static let zodiacs = ["鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪"]
    
    // MARK: - 农历月日
    
    /// 农历日显示文本：初一显示农历月名（正月/冬月/腊月/闰×月），其余显示日次（初二/廿三…）
    static func dayText(for date: Date) -> String {
        // isLeapMonth 走 DateComponents 属性（macOS 10.9+ 老接口，请求 .month 时由日历自动填充）；
        // 不使用 macOS 14+ 新增的 .isLeapMonth 枚举组件，保持最低支持 macOS 13
        let comp = lunar.dateComponents([.month, .day], from: date)
        guard let month = comp.month, let day = comp.day,
              month >= 1, month <= monthNames.count else { return "" }
        if day == 1 {
            let name = monthNames[month - 1]
            return (comp.isLeapMonth == true ? "闰" : "") + name
        }
        guard day >= 1, day <= dayNames.count else { return "" }
        return dayNames[day - 1]
    }
    
    /// 传统节日（按农历月日映射；闰月不重复过节；除夕 = 次日为农历正月初一）
    static func festival(for date: Date) -> String? {
        // isLeapMonth 走 DateComponents 属性（macOS 10.9+ 老接口，请求 .month 时由日历自动填充）；
        // 不使用 macOS 14+ 新增的 .isLeapMonth 枚举组件，保持最低支持 macOS 13
        let comp = lunar.dateComponents([.month, .day], from: date)
        guard let month = comp.month, let day = comp.day, comp.isLeapMonth != true else { return nil }
        switch (month, day) {
        case (1, 1): return "春节"
        case (1, 15): return "元宵节"
        case (5, 5): return "端午节"
        case (7, 7): return "七夕节"
        case (7, 15): return "中元节"
        case (8, 15): return "中秋节"
        case (9, 9): return "重阳节"
        case (12, 8): return "腊八节"
        default: break
        }
        // 除夕判定：次日的农历为正月初一（无需推算腊月廿九/三十，天然兼容大小月）
        if let next = Calendar.current.date(byAdding: .day, value: 1, to: date) {
            let nc = lunar.dateComponents([.month, .day], from: next)
            if nc.month == 1 && nc.day == 1 { return "除夕" }
        }
        return nil
    }
    
    /// 干支年 + 生肖（如「丙午马年」）。
    /// 年界取舍：以农历正月初一为年界（与大众认知一致；命理学以立春为界，此处不采用——
    /// 民用日历场景「春节换属相」是主流认知）。
    /// 锚点：公元 4 年为甲子年（史学惯例），干支索引 = (该农历年正月初一的公历年 − 4) mod 60。
    static func ganzhiZodiacYear(for date: Date) -> String {
        let comp = lunar.dateComponents([.year], from: date)
        guard let lunarYear = comp.year else { return "" }
        var nc = DateComponents()
        nc.year = lunarYear
        nc.month = 1
        nc.day = 1
        guard let springFestival = lunar.date(from: nc) else { return "" }
        let gYear = Calendar.current.component(.year, from: springFestival)
        let index = ((gYear - 4) % 60 + 60) % 60
        return heavenlyStems[index % 10] + earthlyBranches[index % 12] + zodiacs[index % 12] + "年"
    }
    
    // MARK: - 24 节气（天文近似算法自算）
    
    // 节气名按太阳黄经序（春分 0° 起，每 15° 一个）
    private static let solarTermNames = [
        "春分", "清明", "谷雨", "立夏", "小满", "芒种",
        "夏至", "小暑", "大暑", "立秋", "处暑", "白露",
        "秋分", "寒露", "霜降", "立冬", "小雪", "大雪",
        "冬至", "小寒", "大寒", "立春", "雨水", "惊蛰"
    ]
    // 各节气年内预估日期（月, 日），作为二分迭代的初始 bracket 中心（±5 天必然覆盖真值）
    private static let solarTermEstimates: [(month: Int, day: Int)] = [
        (3, 20), (4, 4), (4, 20), (5, 5), (5, 21), (6, 5),
        (6, 21), (7, 7), (7, 22), (8, 7), (8, 23), (9, 7),
        (9, 23), (10, 8), (10, 23), (11, 7), (11, 22), (12, 7),
        (12, 21), (1, 5), (1, 20), (2, 4), (2, 19), (3, 5)
    ]
    // 全年节气时刻缓存（App 生命周期内每年最多计算一次）
    // 访问线程：主线程（视图选中日信息）与后台串行队列（网格模型构建）并存，加锁保护
    private static var solarTermCache: [Int: [Date]] = [:]
    private static let solarTermCacheLock = NSLock()
    
    /// 太阳视黄经（低精度公式）：n 为 J2000.0 起算日数，L 平黄经，g 平近点角；
    /// λ = L + 1.915°·sin g + 0.020°·sin 2g，误差约 ±0.01°（对应节气时刻约 ±15 分钟），民用足够
    private static func sunApparentLongitude(jd: Double) -> Double {
        let n = jd - 2451545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n) * Double.pi / 180
        var lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)).truncatingRemainder(dividingBy: 360)
        if lambda < 0 { lambda += 360 }
        return lambda
    }
    
    /// 二分迭代反求「太阳黄经 = 目标角度」的时刻（黄经单调递增，日行约 0.986°，50 次迭代收敛到秒级）
    private static func findSolarTermTime(longitude: Double, near estimate: Date) -> Date {
        var lo = estimate.addingTimeInterval(-5 * 86400).timeIntervalSince1970
        var hi = estimate.addingTimeInterval(5 * 86400).timeIntervalSince1970
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            let jd = mid / 86400 + 2440587.5
            // 角度差归一化到 (-180, 180]，处理 0° 环绕（春分等黄经过零点的节气）
            var diff = sunApparentLongitude(jd: jd) - longitude
            diff = (diff + 540).truncatingRemainder(dividingBy: 360) - 180
            if diff > 0 { hi = mid } else { lo = mid }
        }
        return Date(timeIntervalSince1970: (lo + hi) / 2)
    }
    
    /// 公历某年的 24 节气时刻（按 solarTermNames 索引序），结果缓存（锁保护，主线程/后台队列均可调用）
    static func solarTermDates(year: Int) -> [Date] {
        solarTermCacheLock.lock()
        defer { solarTermCacheLock.unlock() }
        if let cached = solarTermCache[year] { return cached }
        let cal = Calendar.current
        var dates: [Date] = []
        for (i, est) in solarTermEstimates.enumerated() {
            var comp = DateComponents()
            comp.year = year
            comp.month = est.month
            comp.day = est.day
            comp.hour = 12
            guard let estimate = cal.date(from: comp) else { continue }
            // 节气 i 对应太阳黄经 i×15°（春分 0° 起）
            dates.append(findSolarTermTime(longitude: Double(i * 15), near: estimate))
        }
        solarTermCache[year] = dates
        return dates
    }
    
    /// 该公历日是否为节气日（按本地时区日期判定），返回节气名
    static func solarTerm(for date: Date) -> String? {
        let year = Calendar.current.component(.year, from: date)
        let dates = solarTermDates(year: year)
        for (i, d) in dates.enumerated() {
            if Calendar.current.isDate(d, inSameDayAs: date) {
                return solarTermNames[i]
            }
        }
        return nil
    }
}
