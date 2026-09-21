#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
黄金 CFTC COT 持仓报告抓取工具
==============================

数据来源:
  1. CFTC 官方 Socrata API (publicreporting.cftc.gov)
     - Disaggregated Futures Only COT  (数据集 6dca-aqww)
     - Legacy Futures Only COT         (数据集 jun7-fc8e)
  2. 黄金期货价格 (yfinance, GC=F, 可选)

黄金合约标识:
  CFTC 合约市场代码: 088691
  市场名称: GOLD - COMMODITY EXCHANGE INC. (COMEX)

用法:
  python gold_cot.py latest              # 查看最新一期 COT 报告
  python gold_cot.py history --weeks 52  # 抓取最近 N 周历史并保存 CSV
  python gold_cot.py chart --weeks 156   # 生成持仓/价格走势图
  python gold_cot.py all                 # 以上全部执行
"""

import argparse
import csv
import gzip
import io
import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timedelta
from pathlib import Path


def _ssl_context() -> ssl.SSLContext:
    """优先使用 certifi 证书, 避免部分 Python 环境缺 CA 导致验证失败。"""
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


SSL_CTX = _ssl_context()

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
CHART_DIR = BASE_DIR / "charts"

SOCRATA_BASE = "https://publicreporting.cftc.gov/resource"

# CFTC Socrata 数据集 ID
DATASET_DISAGGREGATED = "6dca-aqww"   # Disaggregated Futures Only
DATASET_LEGACY = "jun7-fc8e"          # Legacy Futures Only

# CFTC 官方历史压缩文件 (备用数据源, Socrata 不可用时自动切换)
DISAGG_ZIP_URL = "https://www.cftc.gov/files/dea/history/fut_disagg_txt_{year}.zip"
LEGACY_ZIP_URL = "https://www.cftc.gov/files/dea/history/deacot{year}.zip"

GOLD_MARKET_CODE = "088691"           # GOLD - COMMODITY EXCHANGE INC.

USER_AGENT = "gold-cot-tracker/1.0 (personal research)"

# 上期所(沪金期权)日行情: 官方 JSON, 含全部期权合约明细
# OPTIONSTYPE: 1=看涨, 2=看跌; PRODUCTGROUPID=au 即沪金期权
SHFE_OPT_KX_URL = ("https://www.shfe.com.cn/data/tradedata/option/"
                   "dailydata/kx{date}.dat?params={ts}")

# 沪金期权上市日 (2022-12-26), 更早的日期没有数据
SHFE_AU_OPT_LIST_DATE = "2022-12-26"

# Legacy 压缩文件的表头 -> Socrata 风格字段名
LEGACY_ZIP_HEADER_MAP = {
    "as of date in form yyyy-mm-dd": "report_date_as_yyyy_mm_dd",
    "cftc contract market code": "cftc_contract_market_code",
    "open interest (all)": "open_interest_all",
    "noncommercial positions-long (all)": "noncomm_positions_long_all",
    "noncommercial positions-short (all)": "noncomm_positions_short_all",
    "noncommercial positions-spreading (all)": "noncomm_positions_spread_all",
    "commercial positions-long (all)": "comm_positions_long_all",
    "commercial positions-short (all)": "comm_positions_short_all",
    "nonreportable positions-long (all)": "nonrept_positions_long_all",
    "nonreportable positions-short (all)": "nonrept_positions_short_all",
}


# ---------------------------------------------------------------------------
# 网络请求
# ---------------------------------------------------------------------------

def socrata_query(dataset_id: str, params: dict) -> list[dict]:
    """向 CFTC Socrata API 发起查询, 返回记录列表。"""
    url = f"{SOCRATA_BASE}/{dataset_id}.json?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20, context=SSL_CTX) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _download(url: str, retries: int = 3, timeout: int = 45) -> bytes:
    """下载文件, 网络抖动时自动重试。"""
    last_exc: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as resp:
                return resp.read()
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
            if attempt < retries - 1:
                print(f"  [提示] 下载中断, 第 {attempt + 2} 次重试...")
    raise last_exc  # type: ignore[misc]


CACHE_DIR = DATA_DIR / "cache"

# 技术分析页数据文件 (页面通过 <script> 标签加载, file:// 直开也可用)
TA_OHLC_CACHE = DATA_DIR / "ta_ohlc.json"     # 日频 OHLC 增量缓存
TA_DATA_JS = DATA_DIR / "ta_data.js"          # 页面读取的数据文件
TA_TEMPLATE = BASE_DIR / "dashboard_ta_template.html"
TA_HTML = BASE_DIR / "dashboard_ta.html"

# 黄金行业平均全维持成本 AISC (美元/盎司) 年度估算值
# 来源为公开行业统计 (WGC / Metals Focus 等) 的近似平均, 仅作估值参考
MINING_COST_AISC = [
    [2010, 850], [2011, 950], [2012, 1050], [2013, 1100], [2014, 1050],
    [2015, 1000], [2016, 1050], [2017, 1100], [2018, 1150], [2019, 1200],
    [2020, 1250], [2021, 1300], [2022, 1400], [2023, 1450], [2024, 1550],
    [2025, 1650], [2026, 1750],
]


def _download_cached(url: str, max_age_hours: float | None) -> bytes:
    """带本地缓存的下载。

    max_age_hours=None 表示永久缓存 (历史年份数据不会变);
    否则缓存超过指定小时数后重新下载。
    """
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_path = CACHE_DIR / url.rsplit("/", 1)[-1]
    if cache_path.exists():
        if max_age_hours is None:
            return cache_path.read_bytes()
        age_h = (datetime.now().timestamp()
                 - cache_path.stat().st_mtime) / 3600
        if age_h < max_age_hours:
            return cache_path.read_bytes()
    data = _download(url)
    cache_path.write_bytes(data)
    return data


def _read_zip_csv(zip_bytes: bytes) -> list[dict]:
    """读取 CFTC 历史 zip 中的 CSV, 返回全部市场的记录列表。"""
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        names = [n for n in zf.namelist()
                 if n.lower().endswith((".txt", ".csv"))]
        if not names:
            return []
        with zf.open(names[0]) as f:
            text = io.TextIOWrapper(f, encoding="utf-8-sig", errors="replace")
            return list(csv.DictReader(text))


def _map_disagg_zip_row(row: dict) -> dict:
    """Disaggregated zip 表头规范化后即为 Socrata 字段名。"""
    return {k.strip().lower().replace("-", "_"): (v or "").strip()
            for k, v in row.items() if k}


def _map_legacy_zip_row(row: dict) -> dict:
    """Legacy zip 表头按映射表转成 Socrata 字段名。"""
    out = {}
    for k, v in row.items():
        if not k:
            continue
        key = LEGACY_ZIP_HEADER_MAP.get(k.strip().lower())
        if key:
            out[key] = (v or "").strip()
    return out


def fetch_gold_cot_zip(dataset_id: str, limit: int) -> list[dict]:
    """备用数据源: 从 CFTC 官方历史 zip 抓取黄金 COT 记录 (倒序)。"""
    tpl = DISAGG_ZIP_URL if dataset_id == DATASET_DISAGGREGATED else LEGACY_ZIP_URL
    mapper = (_map_disagg_zip_row if dataset_id == DATASET_DISAGGREGATED
              else _map_legacy_zip_row)

    this_year = datetime.now().year
    years_needed = max(1, -(-limit * 7 // 365) + 1)  # 覆盖 limit 周所需年数
    records: dict[str, dict] = {}
    for year in range(this_year, this_year - years_needed - 1, -1):
        try:
            # 历史年份永久缓存; 当年数据缓存 12 小时 (每周五更新)
            max_age = 12.0 if year == this_year else None
            blob = _download_cached(tpl.format(year=year), max_age)
            rows = _read_zip_csv(blob)
        except Exception as exc:  # noqa: BLE001
            print(f"  [提示] {year} 年 zip 获取失败 ({exc}), 跳过")
            continue
        for raw in rows:
            rec = mapper(raw)
            if rec.get("cftc_contract_market_code") == GOLD_MARKET_CODE:
                date = rec.get("report_date_as_yyyy_mm_dd", "")
                if date:
                    records[date] = rec
        if len(records) >= limit:
            break

    ordered = sorted(records.values(),
                     key=lambda r: r["report_date_as_yyyy_mm_dd"],
                     reverse=True)
    return ordered[:limit]


def fetch_gold_cot(dataset_id: str, limit: int) -> list[dict]:
    """按报告日期倒序抓取黄金 COT 记录。

    优先使用 Socrata API; 不可用时自动切换到 CFTC 官方历史 zip。
    设置环境变量 GOLD_COT_FORCE_ZIP=1 可强制使用 zip 源
    (Socrata 返回的字段名与该数据集个别版本不一致, 会导致分项持仓为 0,
    因此在 CI 等环境中建议强制 zip 源, 行为与本机一致)。
    """
    if os.environ.get("GOLD_COT_FORCE_ZIP"):
        return fetch_gold_cot_zip(dataset_id, limit)
    try:
        return socrata_query(dataset_id, {
            "cftc_contract_market_code": GOLD_MARKET_CODE,
            "$order": "report_date_as_yyyy_mm_dd DESC",
            "$limit": str(limit),
        })
    except Exception as exc:  # noqa: BLE001
        print(f"  [提示] Socrata API 不可用 ({exc}), 切换到 CFTC 官方 zip 数据源")
        return fetch_gold_cot_zip(dataset_id, limit)


# ---------------------------------------------------------------------------
# 数据整理
# ---------------------------------------------------------------------------

def _i(row: dict, key: str) -> int:
    """安全地把字段转成 int。"""
    try:
        return int(float(row.get(key, 0) or 0))
    except (TypeError, ValueError):
        return 0


def _f(row: dict, key: str) -> float:
    try:
        return float(row.get(key, 0) or 0)
    except (TypeError, ValueError):
        return 0.0


def normalize_disaggregated(row: dict) -> dict:
    """把 Disaggregated 原始记录整理成统一结构 (单位: 手)。"""
    mm_long = _i(row, "m_money_positions_long_all")
    mm_short = _i(row, "m_money_positions_short_all")
    pm_long = _i(row, "prod_merc_positions_long_all")
    pm_short = _i(row, "prod_merc_positions_short_all")
    swap_long = _i(row, "swap_positions_long_all")
    # 注意: CFTC 该字段名里有两个下划线
    swap_short = _i(row, "swap__positions_short_all")
    oth_long = _i(row, "other_rept_positions_long_all")
    oth_short = _i(row, "other_rept_positions_short_all")
    nr_long = _i(row, "nonrept_positions_long_all")
    nr_short = _i(row, "nonrept_positions_short_all")

    return {
        "report_date": row.get("report_date_as_yyyy_mm_dd", "")[:10],
        "open_interest": _i(row, "open_interest_all"),
        # 管理基金 (机构大资金 / 投机主力)
        "mm_long": mm_long,
        "mm_short": mm_short,
        "mm_net": mm_long - mm_short,
        "mm_spread": _i(row, "m_money_positions_spread_all"),
        # 生产商/贸易商 (商业套保)
        "pm_long": pm_long,
        "pm_short": pm_short,
        "pm_net": pm_long - pm_short,
        # 掉期交易商
        "swap_long": swap_long,
        "swap_short": swap_short,
        "swap_net": swap_long - swap_short,
        # 其他报告持仓 (中小型投机商)
        "other_long": oth_long,
        "other_short": oth_short,
        "other_net": oth_long - oth_short,
        # 非报告持仓 (散户 / 小机构)
        "nr_long": nr_long,
        "nr_short": nr_short,
        "nr_net": nr_long - nr_short,
        # 集中度指标
        "pct_oi_mm_long": _f(row, "pct_of_oi_m_money_long_all"),
        "pct_oi_mm_short": _f(row, "pct_of_oi_m_money_short_all"),
        "traders_mm_long": _i(row, "traders_m_money_long_all"),
        "traders_mm_short": _i(row, "traders_m_money_short_all"),
    }


def normalize_legacy(row: dict) -> dict:
    """把 Legacy 原始记录整理成统一结构 (单位: 手)。"""
    nc_long = _i(row, "noncomm_positions_long_all")
    nc_short = _i(row, "noncomm_positions_short_all")
    c_long = _i(row, "comm_positions_long_all")
    c_short = _i(row, "comm_positions_short_all")
    nr_long = _i(row, "nonrept_positions_long_all")
    nr_short = _i(row, "nonrept_positions_short_all")

    return {
        "report_date": row.get("report_date_as_yyyy_mm_dd", "")[:10],
        "open_interest": _i(row, "open_interest_all"),
        # 非商业持仓 (投机)
        "noncomm_long": nc_long,
        "noncomm_short": nc_short,
        "noncomm_net": nc_long - nc_short,
        "noncomm_spread": _i(row, "noncomm_positions_spread_all"),
        # 商业持仓 (套保)
        "comm_long": c_long,
        "comm_short": c_short,
        "comm_net": c_long - c_short,
        # 非报告持仓 (散户)
        "nonrept_long": nr_long,
        "nonrept_short": nr_short,
        "nonrept_net": nr_long - nr_short,
    }


def add_weekly_changes(records: list[dict], keys: list[str]) -> None:
    """records 按日期倒序; 为每个 key 增加 <key>_wow 周环比字段。"""
    for idx, rec in enumerate(records):
        prev = records[idx + 1] if idx + 1 < len(records) else None
        for k in keys:
            rec[f"{k}_wow"] = (rec[k] - prev[k]) if prev else None


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

def fmt(n, plus=False):
    if n is None:
        return "   --"
    sign = "+" if plus and n > 0 else ""
    return f"{sign}{n:,}"


def print_latest_disaggregated(rec: dict) -> None:
    print("=" * 74)
    print(f"  黄金 COT 报告 (Disaggregated, 期货)   报告日期: {rec['report_date']}")
    print("=" * 74)
    print(f"  总持仓量 Open Interest : {fmt(rec['open_interest'])} 手"
          f"   (周环比 {fmt(rec.get('open_interest_wow'), True)})")
    print("-" * 74)
    print(f"  {'类别':<26}{'多头':>12}{'空头':>12}{'净持仓':>12}{'净持仓周变化':>14}")
    print("-" * 74)
    rows = [
        ("管理基金 Managed Money", "mm_long", "mm_short", "mm_net"),
        ("生产商/贸易商 Prod/Merc", "pm_long", "pm_short", "pm_net"),
        ("掉期交易商 Swap Dealers", "swap_long", "swap_short", "swap_net"),
        ("其他报告 Other Reportables", "other_long", "other_short", "other_net"),
    ]
    for name, lk, sk, nk in rows:
        print(f"  {name:<26}{fmt(rec[lk]):>12}{fmt(rec[sk]):>12}"
              f"{fmt(rec[nk], True):>12}{fmt(rec.get(nk + '_wow'), True):>14}")
    print("-" * 74)
    print(f"  管理基金多头占总持仓: {rec['pct_oi_mm_long']:.1f}%   "
          f"空头占总持仓: {rec['pct_oi_mm_short']:.1f}%")
    print(f"  管理基金持仓交易员数: 多头 {rec['traders_mm_long']} 家 / "
          f"空头 {rec['traders_mm_short']} 家")
    # 简单信号解读
    net = rec["mm_net"]
    oi = rec["open_interest"] or 1
    ratio = net / oi
    if ratio > 0.30:
        mood = "投机净多头处于高位, 注意拥挤交易风险"
    elif ratio < 0.05:
        mood = "投机净多头处于低位, 市场情绪偏冷"
    else:
        mood = "投机仓位处于中性区间"
    print(f"  解读: 管理基金净多/总持仓 = {ratio:.1%}, {mood}")
    print("=" * 74)


def print_latest_legacy(rec: dict) -> None:
    print()
    print("=" * 74)
    print(f"  黄金 COT 报告 (Legacy, 期货)          报告日期: {rec['report_date']}")
    print("=" * 74)
    print(f"  {'类别':<26}{'多头':>12}{'空头':>12}{'净持仓':>12}{'净持仓周变化':>14}")
    print("-" * 74)
    rows = [
        ("非商业 Non-Commercial", "noncomm_long", "noncomm_short", "noncomm_net"),
        ("商业 Commercial", "comm_long", "comm_short", "comm_net"),
        ("非报告 Non-Reportable", "nonrept_long", "nonrept_short", "nonrept_net"),
    ]
    for name, lk, sk, nk in rows:
        print(f"  {name:<26}{fmt(rec[lk]):>12}{fmt(rec[sk]):>12}"
              f"{fmt(rec[nk], True):>12}{fmt(rec.get(nk + '_wow'), True):>14}")
    print("=" * 74)


def save_csv(records: list[dict], path: Path) -> None:
    if not records:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    # 按日期升序保存, 便于后续分析
    ordered = sorted(records, key=lambda r: r["report_date"])
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=list(ordered[0].keys()))
        writer.writeheader()
        writer.writerows(ordered)
    print(f"  已保存 {len(ordered)} 条记录 -> {path}")


# ---------------------------------------------------------------------------
# 行情数据 (可选, 依赖 yfinance)
# ---------------------------------------------------------------------------

def fetch_prices(ticker: str, weeks: int, interval: str = "1wk", name: str = ""):
    """抓取指定代码的收盘价序列, 失败时返回 None。interval: 1d / 1wk"""
    label = name or ticker
    try:
        import yfinance as yf
    except ImportError:
        print("  [提示] 未安装 yfinance, 跳过行情数据抓取")
        return None
    try:
        days = weeks * 7 + 10
        df = yf.download(ticker, period=f"{days}d", interval=interval,
                         progress=False, auto_adjust=True)
        if df is None or df.empty:
            return None
        close = df["Close"]
        if hasattr(close, "columns"):  # 新版 yfinance 返回 DataFrame
            close = close.iloc[:, 0]
        return close
    except Exception as exc:  # noqa: BLE001
        print(f"  [提示] {label}抓取失败: {exc}")
        return None


def fetch_gold_prices(weeks: int, interval: str = "1wk"):
    """抓取 COMEX 黄金期货收盘价, 失败时返回 None。"""
    return fetch_prices("GC=F", weeks, interval, name="黄金价格")


def fetch_dxy_prices(weeks: int, interval: str = "1d"):
    """抓取美元指数收盘价, 失败时返回 None (依次尝试现货指数/期货)。"""
    for ticker in ("DX-Y.NYB", "DX=F"):
        prices = fetch_prices(ticker, weeks, interval, name=f"美元指数({ticker})")
        if prices is not None and len(prices) > 0:
            return prices
    return None


def _fetch_pairs_yf(ticker: str, weeks: int, name: str):
    """yfinance 日频收盘价 -> [[日期, 收盘], ...], 失败返回 None。"""
    prices = fetch_prices(ticker, weeks, "1d", name)
    if prices is None or len(prices) == 0:
        return None
    return [[idx.strftime("%Y-%m-%d"), round(float(v), 1)]
            for idx, v in prices.items()]


def _fetch_pairs_eastmoney_range(secid: str, beg: datetime, end: datetime,
                                 name: str):
    """东方财富日 K 线 -> [[日期, 收盘], ...], 失败返回 None。"""
    try:
        url = ("https://push2his.eastmoney.com/api/qt/stock/kline/get"
               f"?secid={secid}&fields1=f1,f2,f3&fields2=f51,f53"
               f"&klt=101&fqt=0&beg={beg:%Y%m%d}&end={end:%Y%m%d}")
        payload = json.loads(_download(url).decode("utf-8"))
        klines = (payload.get("data") or {}).get("klines") or []
        pairs = [[k.split(",")[0], float(k.split(",")[1])] for k in klines]
        return pairs or None
    except Exception as exc:  # noqa: BLE001
        print(f"  [提示] {name}东方财富源抓取失败: {exc}")
        return None


def _fetch_pairs_eastmoney(secid: str, weeks: int, name: str):
    """东方财富日 K 线 -> [[日期, 收盘], ...], 失败返回 None。"""
    end = datetime.now()
    beg = end - timedelta(days=weeks * 7 + 10)
    return _fetch_pairs_eastmoney_range(secid, beg, end, name)


def _fetch_pairs_yf_range(ticker: str, beg: datetime, end: datetime,
                          name: str):
    """yfinance 日频收盘价 -> [[日期, 收盘], ...], 失败返回 None。"""
    try:
        import yfinance as yf
        df = yf.download(ticker, start=beg.strftime("%Y-%m-%d"),
                         end=(end + timedelta(days=1)).strftime("%Y-%m-%d"),
                         interval="1d", progress=False, auto_adjust=True)
        if df is None or df.empty:
            return None
        close = df["Close"]
        if hasattr(close, "columns"):
            close = close.iloc[:, 0]
        return [[idx.strftime("%Y-%m-%d"), round(float(v), 2)]
                for idx, v in close.items()] or None
    except Exception as exc:  # noqa: BLE001
        print(f"  [提示] {name} yfinance 源抓取失败: {exc}")
        return None


def fetch_price_pairs(ticker: str, secid: str, weeks: int, name: str):
    """看板用日频行情: 优先东方财富(快), 失败时回退 yfinance。"""
    pairs = _fetch_pairs_eastmoney(secid, weeks, name)
    if pairs:
        return pairs
    print(f"  [提示] {name}切换到 yfinance 数据源")
    return _fetch_pairs_yf(ticker, weeks, name)


def _fetch_ohlc_eastmoney_range(beg: datetime, end: datetime):
    """东方财富日 K 线 -> [[日期, 开, 收, 高, 低], ...], 失败返回 None。"""
    try:
        url = ("https://push2his.eastmoney.com/api/qt/stock/kline/get"
               "?secid=101.GC00Y&fields1=f1,f2,f3"
               "&fields2=f51,f52,f53,f54,f55"
               f"&klt=101&fqt=0&beg={beg:%Y%m%d}&end={end:%Y%m%d}")
        payload = json.loads(_download(url).decode("utf-8"))
        klines = (payload.get("data") or {}).get("klines") or []
        rows = []
        for k in klines:
            p = k.split(",")  # 日期,开,收,高,低
            rows.append([p[0], float(p[1]), float(p[2]),
                         float(p[3]), float(p[4])])
        return rows or None
    except Exception as exc:  # noqa: BLE001
        print(f"  [提示] 黄金 OHLC 东方财富源失败: {exc}")
        return None


def _fetch_ohlc_yf_range(beg: datetime, end: datetime):
    """yfinance 日频 OHLC -> [[日期, 开, 收, 高, 低], ...], 失败返回 None。"""
    try:
        import yfinance as yf
        df = yf.download("GC=F", start=beg.strftime("%Y-%m-%d"),
                         end=(end + timedelta(days=1)).strftime("%Y-%m-%d"),
                         interval="1d", progress=False, auto_adjust=True)
        if df is None or df.empty:
            return None

        def col(name):
            s = df[name]
            return s.iloc[:, 0] if hasattr(s, "columns") else s

        return [[idx.strftime("%Y-%m-%d"),
                 round(float(o), 1), round(float(c), 1),
                 round(float(h), 1), round(float(l), 1)]
                for idx, o, c, h, l in zip(df.index, col("Open"),
                                           col("Close"), col("High"),
                                           col("Low"))] or None
    except Exception as exc:  # noqa: BLE001
        print(f"  [提示] 黄金 OHLC yfinance 源失败: {exc}")
        return None


def _fetch_ohlc_range(beg: datetime, end: datetime):
    """按日期区间抓黄金日频 OHLC, 东方财富优先, yfinance 兜底。"""
    rows = _fetch_ohlc_eastmoney_range(beg, end)
    if rows:
        return rows
    print("  [提示] 黄金 OHLC 切换到 yfinance 数据源")
    return _fetch_ohlc_yf_range(beg, end)


def fetch_gold_ohlc(weeks: int):
    """COMEX 黄金日频 OHLC -> [[日期, 开, 收, 高, 低], ...], 失败返回 None。

    带本地增量缓存 (data/ta_ohlc.json): 已有历史数据绝不重复抓取,
    每次只补最后几天到今天的缺失数据; 缓存已覆盖到今天时直接返回缓存。
    """
    cutoff = (datetime.now() - timedelta(days=weeks * 7 + 10)
              ).strftime("%Y-%m-%d")
    cached: list[list] = []
    if TA_OHLC_CACHE.exists():
        try:
            cached = json.loads(TA_OHLC_CACHE.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            cached = []
    cached = [r for r in cached
              if isinstance(r, list) and len(r) == 5 and r[0] >= cutoff]

    today = datetime.now().strftime("%Y-%m-%d")
    last = cached[-1][0] if cached else None
    # 3 天新鲜度窗口: 覆盖周末休市, 缓存已接近最新时不再发请求
    if last and (datetime.now() - datetime.strptime(last, "%Y-%m-%d")
                 ).days <= 3:
        print("  [缓存] 黄金 OHLC 已是最新, 无需重复抓取")
        return cached
    if last:
        beg = datetime.strptime(last, "%Y-%m-%d") - timedelta(days=5)
        print(f"  [增量] 黄金 OHLC 仅补齐 {beg:%Y-%m-%d} 以来的缺失数据")
    else:
        beg = datetime.strptime(cutoff, "%Y-%m-%d")
        print(f"  [全量] 黄金 OHLC 抓取 {cutoff} 以来的数据")

    new_rows = _fetch_ohlc_range(beg, datetime.now()) or []
    merged = {r[0]: r for r in cached}
    for r in new_rows:
        merged[r[0]] = r
    rows = sorted(merged.values(), key=lambda r: r[0])
    if rows:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        TA_OHLC_CACHE.write_text(json.dumps(rows, ensure_ascii=False),
                                 encoding="utf-8")
        return rows
    return cached or None


# ---------------------------------------------------------------------------
# 黄金期权 PCR (Put/Call Ratio)
# ---------------------------------------------------------------------------

SHFE_PCR_CACHE = DATA_DIR / "gold_pcr_shfe.json"
COMEX_PCR_CACHE = DATA_DIR / "gold_pcr_comex.json"


def _fetch_shfe_gold_pcr_one(date8: str):
    """抓取单日沪金期权 PCR。

    返回 (row, status): row 为 [YYYY-MM-DD, 成交量PCR, 持仓量PCR] 或 None;
    status: "ok" 有数据 / "nodata" 源站确认无数据(非交易日或期权未上市)
            / "error" 网络失败。PCR = 看跌 / 看涨。
    """
    url = SHFE_OPT_KX_URL.format(date=date8, ts=int(time.time() * 1000))
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT, "Accept-Encoding": "gzip"})
    try:
        with urllib.request.urlopen(req, timeout=15, context=SSL_CTX) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
    except urllib.error.HTTPError as exc:
        # 非交易日: 源站返回 404 (gzip 压缩的 HTML 页)
        if exc.code == 404:
            return None, "nodata"
        return None, "error"
    except Exception:  # noqa: BLE001
        return None, "error"
    # 非交易日返回的是 HTML 404 页
    if not raw.startswith(b"{"):
        return None, "nodata"
    try:
        payload = json.loads(raw)
    except Exception:  # noqa: BLE001
        return None, "error"
    pv = cv = po = co = 0
    for r in payload.get("o_curinstrument") or []:
        if r.get("PRODUCTGROUPID") != "au":
            continue
        vol = r.get("VOLUME") or 0
        oi = r.get("OPENINTEREST") or 0
        if r.get("OPTIONSTYPE") == "1":      # 看涨
            cv += vol
            co += oi
        elif r.get("OPTIONSTYPE") == "2":    # 看跌
            pv += vol
            po += oi
    if not co:                    # 源站无沪金期权数据(休市或尚未上市)
        return None, "nodata"
    pcr_oi = round(po / co, 3)
    pcr_vol = round(pv / cv, 3) if cv else None
    return [f"{date8[:4]}-{date8[4:6]}-{date8[6:]}", pcr_vol, pcr_oi], "ok"


def fetch_shfe_pcr_incremental(weeks: int):
    """沪金期权 PCR 日频序列, 带本地增量缓存 (策略同黄金 OHLC)。

    每次只补缓存中缺失的日期, 已有历史绝不重复抓取;
    源站确认无数据的日期 (周末/节假日/上市前) 记入 gaps, 不再重复请求;
    返回 [[日期, 成交量PCR, 持仓量PCR], ...] (按日期升序)。
    """
    cutoff = (datetime.now() - timedelta(days=weeks * 7 + 10)
              ).strftime("%Y-%m-%d")
    cutoff = max(cutoff, SHFE_AU_OPT_LIST_DATE)
    # 磁盘缓存永久保留全部历史 (重抓历史成本高), 运行期再按窗口过滤;
    # 文件结构: {"rows": [[日期, 成交量PCR, 持仓量PCR]...],
    #            "gaps": [源站确认无数据的日期...]}
    stored: list[list] = []
    gaps: list[str] = []
    if SHFE_PCR_CACHE.exists():
        try:
            blob = json.loads(SHFE_PCR_CACHE.read_text(encoding="utf-8"))
            if isinstance(blob, dict):
                stored, gaps = blob.get("rows") or [], blob.get("gaps") or []
            else:                       # 兼容旧格式: 纯 rows 列表
                stored = blob
        except Exception:  # noqa: BLE001
            stored, gaps = [], []
    stored = [r for r in stored
              if isinstance(r, list) and len(r) == 3 and r[0] >= SHFE_AU_OPT_LIST_DATE]
    cached = [r for r in stored if r[0] >= cutoff]

    today = datetime.now()
    # 补齐窗口 [cutoff, today] 内所有缺失日期 (只请求缺失日,
    # 因此先用小窗口跑过, 再切换大窗口时也会回补中间历史)
    have = {r[0] for r in stored}
    no_data = set(gaps)
    days = []
    d = datetime.strptime(cutoff, "%Y-%m-%d")
    while d <= today:
        if d.strftime("%Y-%m-%d") not in have | no_data:
            days.append(d)
        d += timedelta(days=1)
    if not days:
        print("  [缓存] 沪金期权 PCR 已覆盖抓取窗口, 无需重复抓取")
        return cached
    print(f"  [增量] 沪金期权 PCR 补齐 {days[0]:%Y-%m-%d} ~ "
          f"{days[-1]:%Y-%m-%d} 内 {len(days)} 个缺失日", flush=True)

    # 单线程顺序抓取: 并发高频请求会触发源站限流(连接挂起直至超时)
    fetched: dict[str, list] = {}
    consecutive_errors = 0
    for i, d0 in enumerate(days):
        r, status = _fetch_shfe_gold_pcr_one(d0.strftime("%Y%m%d"))
        if r:
            fetched[r[0]] = r
            consecutive_errors = 0
        elif status == "nodata":   # 源站确认无数据, 记录后不再请求
            gaps.append(d0.strftime("%Y-%m-%d"))
            consecutive_errors = 0
        else:
            consecutive_errors += 1
            if consecutive_errors >= 5:
                print("  [提示] 连续多次请求失败, 疑似网络受限或源站限流,"
                      " 提前中止; 已抓数据已保存, 请稍后重试")
                break
        if len(days) > 30 and (i + 1) % 50 == 0:
            print(f"    进度 {i + 1}/{len(days)}", flush=True)

    merged = {r[0]: r for r in stored}
    merged.update(fetched)
    rows = sorted(merged.values(), key=lambda r: r[0])
    if fetched or gaps:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        SHFE_PCR_CACHE.write_text(json.dumps(
            {"rows": rows, "gaps": sorted(set(gaps))}, ensure_ascii=False),
            encoding="utf-8")
    out = [r for r in rows if r[0] >= cutoff]
    print(f"  [完成] 沪金期权 PCR 共 {len(out)} 条 (本次新增 {len(fetched)})")
    if not stored and not fetched:
        print("  [提示] 未获取到任何数据, 请检查网络;"
              " 若报证书错误请安装 certifi: pip install certifi")
    return out


def _fetch_comex_pcr_yahoo_snapshot() -> list[list] | None:
    """Yahoo 期权链当日快照: 汇总 GC=F 最近 2 个到期月的看涨/看跌成交量。

    期权链只有当前快照、没有历史, 只能补当天这一条;
    配合 CI 每日运行可逐日累积出时间序列。任何失败返回 None。
    """
    try:
        import yfinance as yf
        t = yf.Ticker("GC=F")
        pv = cv = 0.0
        used = 0
        for exp in list(t.options)[:2]:
            ch = t.option_chain(exp)
            cv += float(ch.calls["volume"].fillna(0).sum())
            pv += float(ch.puts["volume"].fillna(0).sum())
            used += 1
        if not used or cv <= 0:
            return None
        return [[datetime.now().strftime("%Y-%m-%d"), round(pv / cv, 3)]]
    except Exception:  # noqa: BLE001
        return None


def fetch_comex_pcr(weeks: int) -> list[list] | None:
    """COMEX 黄金期权 PCR, best-effort, 双数据源自动互补:

    1. Barchart 历史序列 (可一次回填整段历史, 但有反爬/区域限制)
    2. Yahoo 期权链当日快照 (无历史, 只补当天; CI 每日运行逐日累积)

    返回 [[日期, 成交量PCR], ...] (按日期升序); 全部失败返回旧缓存或 None,
    不影响看板其余部分。
    """
    rows = _fetch_comex_pcr_barchart(weeks)
    # Barchart 拿不到最新交易日(或整体失败只剩旧缓存)时, 用 Yahoo 快照补当天
    today = datetime.now().strftime("%Y-%m-%d")
    last = rows[-1][0] if rows else None
    if last != today:
        snap = _fetch_comex_pcr_yahoo_snapshot()
        if snap:
            merged = {r[0]: r for r in (rows or [])}
            merged.update({r[0]: r for r in snap})
            rows = sorted(merged.values(), key=lambda r: r[0])
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            COMEX_PCR_CACHE.write_text(json.dumps(rows, ensure_ascii=False),
                                       encoding="utf-8")
    return rows or None


def _fetch_comex_pcr_barchart(weeks: int):
    """COMEX 黄金期权 PCR (Barchart 数据源), best-effort。

    Barchart 有反爬/区域限制, 任何一步失败都静默降级:
    返回旧缓存数据或 None, 不影响看板其余部分。
    数据可用时缓存到 data/gold_pcr_comex.json。
    """
    cutoff = (datetime.now() - timedelta(days=weeks * 7 + 10)
              ).strftime("%Y-%m-%d")
    cached: list[list] = []
    if COMEX_PCR_CACHE.exists():
        try:
            cached = json.loads(COMEX_PCR_CACHE.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            cached = []
    cached = [r for r in cached
              if isinstance(r, list) and len(r) == 2 and r[0] >= cutoff]

    today = datetime.now()
    last = cached[-1][0] if cached else None
    if last and (today - datetime.strptime(last, "%Y-%m-%d")).days <= 3:
        return cached

    try:
        import http.cookiejar
        cj = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(cj))
        opener.addheaders = [
            ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                           "AppleWebKit/537.36 (KHTML, like Gecko) "
                           "Chrome/120.0 Safari/537.36"),
            ("Accept", "application/json, text/plain, */*"),
        ]
        # 取最近交割月合约符号, 如 GCV26 (2026年10月)
        sym = "GC" + today.strftime("%y%m")
        page = opener.open(
            f"https://www.barchart.com/futures/quotes/{sym}/"
            "options/put-call-ratios", timeout=20)
        page.read()
        xsrf = next((c.value for c in cj if c.name == "XSRF-TOKEN"), None)
        if not xsrf:
            return cached or None
        # 一次请求拉全窗口区间, 源站自然补齐历史缺口
        beg = today - timedelta(days=weeks * 7 + 10)
        url = ("https://www.barchart.com/proxies/core-api/v1/historical/get"
               f"?symbol={sym}&fields=symbol,timestamp,putCallRatio"
               f"&startDate={beg:%Y-%m-%d}&endDate={today:%Y-%m-%d}"
               "&orderBy=timestamp&orderDir=asc")
        req = urllib.request.Request(
            url, headers={"X-XSRF-TOKEN": urllib.parse.unquote(xsrf)})
        payload = json.loads(opener.open(req, timeout=20).read())
        raw_rows = (payload.get("data") or payload.get("results")
                    or payload.get("dataList") or [])
        new_rows = []
        for r in raw_rows:
            ts = r.get("timestamp")
            pcr = r.get("putCallRatio")
            if ts is None or pcr is None:
                continue
            d0 = datetime.fromtimestamp(
                ts / 1000 if ts > 10**11 else ts).strftime("%Y-%m-%d")
            new_rows.append([d0, round(float(pcr), 3)])
        merged = {r[0]: r for r in cached}
        merged.update({r[0]: r for r in new_rows})
        rows = sorted(merged.values(), key=lambda r: r[0])
        if new_rows:
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            COMEX_PCR_CACHE.write_text(json.dumps(rows, ensure_ascii=False),
                                       encoding="utf-8")
        return rows
    except Exception:  # noqa: BLE001
        return cached or None


# ---------------------------------------------------------------------------
# 图表
# ---------------------------------------------------------------------------

def make_chart(records: list[dict], weeks: int) -> None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates
    except ImportError:
        print("  [错误] 需要 matplotlib 才能生成图表")
        return

    ordered = sorted(records, key=lambda r: r["report_date"])
    dates = [datetime.strptime(r["report_date"], "%Y-%m-%d") for r in ordered]
    mm_net = [r["mm_net"] for r in ordered]
    oi = [r["open_interest"] for r in ordered]

    # 中文字体: 优先 daimon_runtime 内置方案, 否则从系统字体中探测
    try:
        sys.path.insert(0, str(Path(sys.executable).parent.parent.parent))
        from daimon_runtime import setup_plot
        setup_plot()
    except Exception:  # noqa: BLE001
        from matplotlib import font_manager
        available = {f.name for f in font_manager.fontManager.ttflist}
        for font in ("PingFang SC", "Hiragino Sans GB",
                     "Arial Unicode MS", "SimHei", "Noto Sans CJK SC"):
            if font in available:
                plt.rcParams["font.family"] = font
                break
        plt.rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(3, 1, figsize=(12, 10), sharex=True,
                             gridspec_kw={"height_ratios": [2, 1, 1]})

    # 图1: 管理基金净持仓 vs 金价
    ax1 = axes[0]
    ax1.bar(dates, mm_net, width=5.0,
            color=["#d62728" if v >= 0 else "#2ca02c" for v in mm_net],
            alpha=0.7, label="管理基金净持仓 (手)")
    ax1.set_ylabel("净持仓 (手)")
    ax1.axhline(0, color="black", linewidth=0.5)
    ax1.legend(loc="upper left")
    ax1.set_title("黄金 CFTC COT: 管理基金净持仓 vs 金价")

    prices = fetch_gold_prices(weeks)
    if prices is not None:
        ax1b = ax1.twinx()
        ax1b.plot(prices.index, prices.values, color="#ff9900",
                  linewidth=1.2, label="COMEX 黄金期货 (美元/盎司)")
        ax1b.set_ylabel("金价 (USD/oz)")
        ax1b.legend(loc="upper right")

    # 图2: 多空分项
    ax2 = axes[1]
    ax2.plot(dates, [r["mm_long"] for r in ordered],
             color="#d62728", linewidth=1.2, label="管理基金多头")
    ax2.plot(dates, [r["mm_short"] for r in ordered],
             color="#2ca02c", linewidth=1.2, label="管理基金空头")
    ax2.set_ylabel("持仓 (手)")
    ax2.legend(loc="upper left")
    ax2.set_title("管理基金多空分项")

    # 图3: 总持仓量
    ax3 = axes[2]
    ax3.fill_between(dates, oi, color="#1f77b4", alpha=0.4)
    ax3.set_ylabel("总持仓 (手)")
    ax3.set_title("Open Interest 总持仓量")
    ax3.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))

    fig.tight_layout()
    CHART_DIR.mkdir(parents=True, exist_ok=True)
    out = CHART_DIR / f"gold_cot_{ordered[-1]['report_date']}.png"
    fig.savefig(out, dpi=150, bbox_inches="tight")
    print(f"  图表已保存 -> {out}")


# ---------------------------------------------------------------------------
# 命令
# ---------------------------------------------------------------------------

def load_history(weeks: int, with_legacy: bool = True
                 ) -> tuple[list[dict], list[dict]]:
    """抓取并整理历史数据, 返回 (disaggregated, legacy)。"""
    print(f"正在从 CFTC 抓取黄金 COT 数据 (最近 {weeks} 周)...")
    disagg_raw = fetch_gold_cot(DATASET_DISAGGREGATED, weeks)
    legacy_raw = (fetch_gold_cot(DATASET_LEGACY, weeks)
                  if with_legacy else [])
    if not disagg_raw:
        print("  [错误] 未获取到 Disaggregated 数据, 请检查网络")
        sys.exit(1)

    disagg = [normalize_disaggregated(r) for r in disagg_raw]
    legacy = [normalize_legacy(r) for r in legacy_raw]
    add_weekly_changes(disagg, ["open_interest", "mm_net", "pm_net",
                                "swap_net", "other_net"])
    add_weekly_changes(legacy, ["open_interest", "noncomm_net", "comm_net"])
    return disagg, legacy


def cmd_latest(weeks: int = 2) -> None:
    disagg, legacy = load_history(max(weeks, 2))
    print_latest_disaggregated(disagg[0])
    if legacy:
        print_latest_legacy(legacy[0])


def cmd_history(weeks: int) -> None:
    disagg, legacy = load_history(weeks)
    save_csv(disagg, DATA_DIR / "gold_cot_disaggregated.csv")
    if legacy:
        save_csv(legacy, DATA_DIR / "gold_cot_legacy.csv")


def cmd_chart(weeks: int) -> None:
    disagg, _ = load_history(weeks)
    make_chart(disagg, weeks)


# ---------------------------------------------------------------------------
# 交互式看板
# ---------------------------------------------------------------------------

DXY_CACHE = DATA_DIR / "dxy_daily.json"


def fetch_dxy_pairs_incremental(weeks: int):
    """美元指数日频收盘价, 带本地增量缓存 (策略同黄金 OHLC):
    已有历史绝不重复抓取, 缓存接近最新时直接跳过网络请求。"""
    cutoff = (datetime.now() - timedelta(days=weeks * 7 + 10)
              ).strftime("%Y-%m-%d")
    cached: list[list] = []
    if DXY_CACHE.exists():
        try:
            cached = json.loads(DXY_CACHE.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            cached = []
    cached = [r for r in cached
              if isinstance(r, list) and len(r) == 2 and r[0] >= cutoff]

    last = cached[-1][0] if cached else None
    if last and (datetime.now() - datetime.strptime(last, "%Y-%m-%d")
                 ).days <= 3:
        print("  [缓存] 美元指数已是最新, 无需重复抓取")
        return cached
    if last:
        beg = datetime.strptime(last, "%Y-%m-%d") - timedelta(days=5)
        print(f"  [增量] 美元指数仅补齐 {beg:%Y-%m-%d} 以来的缺失数据")
    else:
        beg = datetime.strptime(cutoff, "%Y-%m-%d")
        print(f"  [全量] 美元指数抓取 {cutoff} 以来的数据")

    end = datetime.now()
    new_pairs = _fetch_pairs_eastmoney_range("100.UDI", beg, end, "美元指数")
    if not new_pairs:
        print("  [提示] 美元指数切换到 yfinance 数据源")
        new_pairs = _fetch_pairs_yf_range("DX-Y.NYB", beg, end, "美元指数")
    new_pairs = new_pairs or []

    merged = {r[0]: r for r in cached}
    for r in new_pairs:
        merged[r[0]] = r
    pairs = sorted(merged.values(), key=lambda r: r[0])
    if pairs:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        DXY_CACHE.write_text(json.dumps(pairs, ensure_ascii=False),
                             encoding="utf-8")
        return pairs
    return cached or None


def build_ta_data(weeks: int) -> dict | None:
    """组装技术分析页数据 (OHLC 走增量缓存 + 开采成本常量)。"""
    ohlc = fetch_gold_ohlc(weeks)
    if not ohlc:
        return None
    return {
        "updated": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "ohlc": ohlc,
        "cost": MINING_COST_AISC,
    }


def write_ta_files(ta: dict) -> None:
    """写出技术分析页: 数据文件 ta_data.js + 页面 dashboard_ta.html。"""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    TA_DATA_JS.write_text("window.TA_DATA = "
                          + json.dumps(ta, ensure_ascii=False) + ";\n",
                          encoding="utf-8")
    html = TA_TEMPLATE.read_text(encoding="utf-8")
    TA_HTML.write_text(html, encoding="utf-8")


def cmd_ta(weeks: int) -> None:
    """只更新技术分析页数据, 不抓取 CFTC COT 持仓数据。"""
    print(f"正在更新技术分析页数据 (最近 {weeks} 周行情)...")
    ta = build_ta_data(weeks)
    if not ta:
        print("  [错误] 行情数据获取失败, 保留旧数据文件")
        return
    write_ta_files(ta)
    print(f"  技术分析页数据已更新 -> {TA_DATA_JS}")
    print(f"  页面 {TA_HTML.name} 打开后每 60 秒自动重载数据,"
          " 也可点\"刷新数据\"按钮手动刷新")


def cmd_dashboard(weeks: int) -> None:
    """生成可交互的 HTML 看板: 持仓页 dashboard.html + 技术分析页 dashboard_ta.html。"""
    disagg, _ = load_history(weeks, with_legacy=False)
    ordered = sorted(disagg, key=lambda r: r["report_date"])

    # 数据 sanity check: 最新一期分项持仓不应全为 0
    latest = ordered[-1]
    if not latest["mm_long"] and not latest["mm_short"]:
        print("  [警告] 最新一期管理基金多空持仓为 0, 数据源字段可能不匹配,"
              " 建议设置 GOLD_COT_FORCE_ZIP=1 使用官方 zip 源")

    cot_data = [{
        "d": r["report_date"],
        "net": r["mm_net"],
        "lo": r["mm_long"],
        "sh": r["mm_short"],
        "oi": r["open_interest"],
        "pm": r["pm_net"],
        "sw": r["swap_net"],
        "oth": r["other_net"],
        "nr": r["nr_net"],
    } for r in ordered]

    # 行情用日频数据; OHLC 走本地增量缓存, 已有历史不会重复抓取
    ohlc_data = fetch_gold_ohlc(weeks)
    price_data = ([[r[0], r[2]] for r in ohlc_data] if ohlc_data
                  else fetch_price_pairs("GC=F", "101.GC00Y", weeks, "黄金价格"))
    dxy_data = fetch_dxy_pairs_incremental(weeks)

    # 黄金期权 PCR: 沪金期权(上期所官方, 主源) + COMEX(Barchart, best-effort)
    print("正在抓取黄金期权 PCR ...")
    pcr_shfe = fetch_shfe_pcr_incremental(weeks)
    pcr_comex = fetch_comex_pcr(weeks)
    if not pcr_comex:
        print("  [提示] COMEX 期权 PCR 暂不可用 (Barchart/Yahoo 均受限),"
              " 看板将只显示沪金期权 PCR")
    pcr_data = {"shfe": pcr_shfe or [], "comex": pcr_comex or None}

    tpl_path = BASE_DIR / "dashboard_template.html"
    html = tpl_path.read_text(encoding="utf-8")
    html = html.replace("/*__COT_DATA__*/[]",
                        json.dumps(cot_data, ensure_ascii=False))
    html = html.replace("/*__DXY_DATA__*/null",
                        json.dumps(dxy_data, ensure_ascii=False))
    html = html.replace("/*__PRICE_DATA__*/null",
                        json.dumps(price_data, ensure_ascii=False))
    html = html.replace("/*__PCR_DATA__*/null",
                        json.dumps(pcr_data, ensure_ascii=False))

    out = BASE_DIR / "dashboard.html"
    out.write_text(html, encoding="utf-8")
    print(f"  持仓看板已生成 -> {out}")

    # 技术分析页: 独立数据文件 (ta_data.js), 与持仓页数据互不干扰
    ta = build_ta_data(weeks)
    if ta:
        write_ta_files(ta)
        print(f"  技术分析页已生成 -> {TA_HTML}")
    else:
        print("  [提示] 技术分析页行情获取失败, 保留旧数据"
              " (可稍后单独运行 ./run.sh ta 补齐)")
    print("  用浏览器打开 dashboard.html 即可, 两页之间可互相跳转")
    print("  技术分析页: 每 60 秒自动重载 + 手动刷新按钮;"
          " 行情增量更新请运行 ./run.sh ta (不触碰 COT 数据)")


def cmd_all(weeks: int) -> None:
    disagg, legacy = load_history(weeks)
    print_latest_disaggregated(disagg[0])
    if legacy:
        print_latest_legacy(legacy[0])
    save_csv(disagg, DATA_DIR / "gold_cot_disaggregated.csv")
    if legacy:
        save_csv(legacy, DATA_DIR / "gold_cot_legacy.csv")
    make_chart(disagg, weeks)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="黄金 CFTC COT 持仓报告抓取工具")
    parser.add_argument("command",
                        choices=["latest", "history", "chart", "dashboard",
                                 "ta", "all"],
                        help="latest=最新报告 history=保存CSV chart=出图 "
                             "dashboard=交互看板(持仓+技术分析两页) "
                             "ta=只刷新技术分析页行情 all=全部")
    parser.add_argument("--weeks", type=int, default=156,
                        help="抓取最近多少周的数据 (默认 156 周 ≈ 3 年)")
    args = parser.parse_args()

    if args.command == "latest":
        cmd_latest()
    elif args.command == "history":
        cmd_history(args.weeks)
    elif args.command == "chart":
        cmd_chart(args.weeks)
    elif args.command == "dashboard":
        cmd_dashboard(args.weeks)
    elif args.command == "ta":
        cmd_ta(args.weeks)
    else:
        cmd_all(args.weeks)


if __name__ == "__main__":
    main()
