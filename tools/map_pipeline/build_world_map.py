#!/usr/bin/env python3
"""世界地图导入管线：Natural Earth（公共领域）-> Godot 可用的贴图与数据。

输出：
  assets/map/relief/relief_<col>_<row>.png   灰色晕渲底图，原始最高精度 21600x10800 切成 4x2 块（无损）
  assets/map/region_ids.png                  地区索引图（半分辨率 10800x5400，8 位灰度，像素值 = 地区索引，0 = 海洋）
  data/map/world_map.json                    地区元数据（名称、标注点、范围）+ 矢量边界线
  data/scenarios/world.json                  模拟用场景：地区人口/特征 + 陆/海/空连接
                                             （若文件已存在，保留其中手调过的 rules / labels）

地图坐标：1 单位 = 1 个底图像素 = 1/60 度（等距圆柱投影）
  x = (lon + 180) * 60,  y = (90 - lat) * 60

用法：
  pip install -r tools/map_pipeline/requirements.txt
  python3 tools/map_pipeline/build_world_map.py            # 全部生成
  python3 tools/map_pipeline/build_world_map.py --skip-relief   # 只重建数据（不切底图，快）
"""
from __future__ import annotations

import argparse
import json
import math
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import shapefile  # pyshp
from PIL import Image, ImageDraw
from scipy.spatial import cKDTree

Image.MAX_IMAGE_PIXELS = None

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path(__file__).resolve().parent / ".cache"

SOURCES = {
    # 灰色晕渲 + 海底地形 + 水系，最高精度版本
    "relief": ("https://naciscdn.org/naturalearth/10m/raster/GRAY_HR_SR_OB_DR.zip", "GRAY_HR_SR_OB_DR.tif"),
    # 国家边界，中国视角（台湾并入中国版图）
    "countries": ("https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_0_countries_chn.zip",
                  "ne_10m_admin_0_countries_chn.shp"),
}

MAP_W, MAP_H = 21600, 10800
PX_PER_DEG = 60
TILE = 5400
ID_SCALE = 2                     # 索引图相对底图的缩小倍数
BORDER_TOLERANCE = 0.5           # 边界线简化容差（底图像素），小于半个像素，肉眼无损

# ---- 数据修正（中国视角） -------------------------------------------------
NAME_OVERRIDES = {
    "CHN": "中国", "HKG": "中国香港", "MAC": "中国澳门",
    "PRK": "朝鲜", "KOR": "韩国", "IOA": "澳属印度洋领地",
}
# Natural Earth 中国视角数据把台湾并入中国多边形，但 POP_EST 仍是大陆人口（2019），补上台湾地区人口。
POPULATION_ADD = {"CHN": 23_600_000}
# 并入其他地区显示与模拟的要素
MERGE_INTO = {"SCR": "CHN"}      # 黄岩岛
# 索引图上相邻、但现实中隔海的地区对：改为海路
NOT_LAND = {("AUS", "PNG"), ("VGB", "VIR"), ("BHR", "QAT")}
# 不参与模拟（仍绘制在地图上，显示为中性）
EXCLUDE = {"ATA"}                # 南极洲
MIN_POPULATION = 1000

# ---- 连接生成参数 ---------------------------------------------------------
SEA_RADIUS_KM = 700              # 海岸间距离小于此值才可能有海路
SEA_NEIGHBORS = 4                # 每个国家保留最近的几个海路邻居
AIR_HUBS = 25                    # 按 GDP 取前 N 个为航空枢纽
AIR_HUB_NEIGHBORS = 6            # 枢纽之间：每个枢纽连最近的几个枢纽
AIR_FEEDERS = 2                  # 普通国家：连最近的几个枢纽
AIR_MIN_POPULATION = 500_000
EARTH_R = 6371.0


# --------------------------------------------------------------------------
def fetch(key: str) -> Path:
    url, inner = SOURCES[key]
    CACHE.mkdir(parents=True, exist_ok=True)
    target_dir = CACHE / key
    target = target_dir / inner
    if target.exists():
        return target
    zpath = CACHE / Path(url).name
    if not zpath.exists():
        print(f"下载 {url}")
        urllib.request.urlretrieve(url, zpath)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(target_dir)
    return target


def lonlat_to_px(lon, lat):
    return (np.asarray(lon) + 180.0) * PX_PER_DEG, (90.0 - np.asarray(lat)) * PX_PER_DEG


def px_to_unit(x, y):
    lon = np.radians(x / PX_PER_DEG - 180.0)
    lat = np.radians(90.0 - y / PX_PER_DEG)
    return np.stack([np.cos(lat) * np.cos(lon), np.cos(lat) * np.sin(lon), np.sin(lat)], axis=-1)


def km_to_chord(km: float) -> float:
    return 2.0 * math.sin(km / EARTH_R / 2.0)


def chord_to_km(c):
    return 2.0 * EARTH_R * np.arcsin(np.clip(np.asarray(c) / 2.0, 0, 1))


def great_circle_km(a, b) -> float:
    (lon1, lat1), (lon2, lat2) = map(lambda p: (math.radians(p[0]), math.radians(p[1])), (a, b))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * EARTH_R * math.asin(math.sqrt(min(h, 1.0)))


def signed_area(pts: np.ndarray) -> float:
    x, y = pts[:, 0], pts[:, 1]
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))


def simplify(pts: np.ndarray, tol: float) -> np.ndarray:
    """Douglas-Peucker（迭代版）。"""
    n = len(pts)
    if n < 3:
        return pts
    keep = np.zeros(n, dtype=bool)
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        s, e = stack.pop()
        if e <= s + 1:
            continue
        a, b = pts[s], pts[e]
        seg = pts[s + 1:e]
        ab = b - a
        length = math.hypot(ab[0], ab[1])
        if length == 0.0:
            d = np.hypot(seg[:, 0] - a[0], seg[:, 1] - a[1])
        else:
            d = np.abs(ab[0] * (seg[:, 1] - a[1]) - ab[1] * (seg[:, 0] - a[0])) / length
        i = int(np.argmax(d))
        if d[i] > tol:
            m = s + 1 + i
            keep[m] = True
            stack.append((s, m))
            stack.append((m, e))
    return pts[keep]


def split_artificial_edges(pts: np.ndarray) -> list[np.ndarray]:
    """去掉沿 ±180° 经线和南极点的人为切割边，只保留真实边界/海岸线。"""
    eps = 0.01
    on_w = pts[:, 0] <= eps
    on_e = pts[:, 0] >= MAP_W - eps
    on_s = pts[:, 1] >= MAP_H - eps
    bad = (on_w[:-1] & on_w[1:]) | (on_e[:-1] & on_e[1:]) | (on_s[:-1] & on_s[1:])
    out, start = [], 0
    for i in np.nonzero(bad)[0]:
        if i + 1 - start >= 2:
            out.append(pts[start:i + 1])
        start = i + 1
    if len(pts) - start >= 2:
        out.append(pts[start:])
    return out


# --------------------------------------------------------------------------
def load_features(shp_path: Path) -> list[dict]:
    sf = shapefile.Reader(str(shp_path.with_suffix("")))
    feats: dict[str, dict] = {}
    pending_merge = []
    for sr in sf.iterShapeRecords():
        r = sr.record.as_dict()
        code = (r.get("ADM0_A3_CN") or r["ADM0_A3"]).strip()
        rings = []
        parts = list(sr.shape.parts) + [len(sr.shape.points)]
        pts_all = np.asarray(sr.shape.points, dtype=np.float64)
        for i in range(len(parts) - 1):
            ring = pts_all[parts[i]:parts[i + 1]]
            if len(ring) >= 3:
                rings.append(ring)
        if code in MERGE_INTO:
            pending_merge.append((MERGE_INTO[code], rings))
            continue
        assert code not in feats, f"duplicate code {code}"
        pop = float(r["POP_EST"] or 0) + POPULATION_ADD.get(code, 0)
        feats[code] = {
            "code": code,
            "name": NAME_OVERRIDES.get(code, r["NAME_ZH"] or r["NAME"]),
            "name_en": r["NAME_EN"] or r["NAME"],
            "population": pop,
            "income": r["INCOME_GRP"] or "",
            "gdp": float(r["GDP_MD"] or 0),
            "labelrank": int(r["LABELRANK"] or 9),
            "label_lonlat": (float(r["LABEL_X"]), float(r["LABEL_Y"])),
            "rings": rings,
        }
    for target, rings in pending_merge:
        feats[target]["rings"].extend(rings)
    out = sorted(feats.values(), key=lambda f: f["code"])
    for i, f in enumerate(out):
        f["index"] = i + 1                      # 0 留给海洋
        f["active"] = f["population"] >= MIN_POPULATION and f["code"] not in EXCLUDE
    assert len(out) <= 255, "索引图为 8 位，最多 255 个地区"
    return out


def rasterize_ids(feats: list[dict]) -> np.ndarray:
    w, h = MAP_W // ID_SCALE, MAP_H // ID_SCALE
    ids = np.zeros((h, w), dtype=np.uint8)
    scale = PX_PER_DEG / ID_SCALE

    def ring_px(ring):
        return np.column_stack([(ring[:, 0] + 180.0) * scale - 0.5, (90.0 - ring[:, 1]) * scale - 0.5])

    # 先画大的，再画小的：飞地/小国覆盖在上层
    def extent(f):
        allp = np.vstack(f["rings"])
        return float(np.ptp(allp[:, 0]) * np.ptp(allp[:, 1]))

    for f in sorted(feats, key=extent, reverse=True):
        rings_px = [ring_px(r) for r in f["rings"]]
        allp = np.vstack(rings_px)
        x0, y0 = max(int(math.floor(allp[:, 0].min())) - 1, 0), max(int(math.floor(allp[:, 1].min())) - 1, 0)
        x1, y1 = min(int(math.ceil(allp[:, 0].max())) + 2, w), min(int(math.ceil(allp[:, 1].max())) + 2, h)
        mask = Image.new("1", (max(x1 - x0, 1), max(y1 - y0, 1)), 0)
        d = ImageDraw.Draw(mask)
        # shapefile 约定：外环顺时针、内环（洞）逆时针。经纬度 y 向上，顺时针 => 有符号面积 < 0
        outers = [p for p, r in zip(rings_px, f["rings"]) if signed_area(r) < 0]
        holes = [p for p, r in zip(rings_px, f["rings"]) if signed_area(r) >= 0]
        for p in outers:
            d.polygon([(x - x0, y - y0) for x, y in p], fill=1)
        for p in holes:
            d.polygon([(x - x0, y - y0) for x, y in p], fill=0)
        m = np.array(mask, dtype=bool)
        ids[y0:y1, x0:x1][m] = f["index"]

    # 太小而没有任何像素的地区（岛国、微型国家）：在标注点放一个 3x3 色块，保证可点击、可相邻
    present = np.bincount(ids.ravel(), minlength=256)
    for f in feats:
        if present[f["index"]] == 0:
            lx, ly = f["label_lonlat"]
            cx, cy = int((lx + 180.0) * scale), int((90.0 - ly) * scale)
            ids[max(cy - 1, 0):cy + 2, max(cx - 1, 0):cx + 2] = f["index"]
            print(f"  小地区补点: {f['code']} {f['name']}")
    return ids


def land_adjacency(ids: np.ndarray) -> dict[tuple[int, int], int]:
    pairs = []
    for a, b in ((ids[:, :-1], ids[:, 1:]), (ids[:-1, :], ids[1:, :]), (ids[:, -1:], ids[:, :1])):
        m = (a != b) & (a > 0) & (b > 0)
        lo = np.minimum(a[m], b[m]).astype(np.int32)
        hi = np.maximum(a[m], b[m]).astype(np.int32)
        pairs.append(lo * 256 + hi)
    keys, counts = np.unique(np.concatenate(pairs), return_counts=True)
    return {(int(k) // 256, int(k) % 256): int(c) for k, c in zip(keys, counts)}


def coastal_points(ids: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """海岸像素（陆地且四邻有海洋），按 0.25° 网格去重。返回 (单位向量, 所属索引)。"""
    land = ids > 0
    sea = ~land
    coast = np.zeros_like(land)
    coast[1:, :] |= land[1:, :] & sea[:-1, :]
    coast[:-1, :] |= land[:-1, :] & sea[1:, :]
    coast[:, 1:] |= land[:, 1:] & sea[:, :-1]
    coast[:, :-1] |= land[:, :-1] & sea[:, 1:]
    ys, xs = np.nonzero(coast)
    owners = ids[ys, xs]
    cell = int(0.25 * PX_PER_DEG / ID_SCALE)
    key = (ys // cell).astype(np.int64) * 100000 * 256 + (xs // cell).astype(np.int64) * 256 + owners
    _, first = np.unique(key, return_index=True)
    xs, ys, owners = xs[first], ys[first], owners[first]
    return px_to_unit((xs + 0.5) * ID_SCALE, (ys + 0.5) * ID_SCALE), owners


def sea_links(ids: np.ndarray, active_idx: set[int], land: dict) -> list[tuple[int, int, float]]:
    pts, owners = coastal_points(ids)
    keep = np.isin(owners, list(active_idx))
    pts, owners = pts[keep], owners[keep]
    tree = cKDTree(pts)
    radius = km_to_chord(SEA_RADIUS_KM)
    best: dict[int, dict[int, float]] = {}
    for idx in np.unique(owners):
        mine = pts[owners == idx]
        near: dict[int, float] = {}
        for hits, p in zip(tree.query_ball_point(mine, radius), mine):
            for j in hits:
                o = int(owners[j])
                if o == idx:
                    continue
                dist = float(np.linalg.norm(pts[j] - p))
                if dist < near.get(o, 9.0):
                    near[o] = dist
        if not near:
            # 偏远岛国：连到最近的海岸国家，不限距离
            dists, js = tree.query(mine, k=min(64, len(pts)))
            for drow, jrow in zip(np.atleast_2d(dists), np.atleast_2d(js)):
                for dist, j in zip(drow, jrow):
                    o = int(owners[j])
                    if o != idx and dist < near.get(o, 9.0):
                        near[o] = float(dist)
            near = dict(sorted(near.items(), key=lambda kv: kv[1])[:1])
        best[int(idx)] = near
    chosen: dict[tuple[int, int], float] = {}
    for a, near in best.items():
        for b, dist in sorted(near.items(), key=lambda kv: kv[1])[:SEA_NEIGHBORS]:
            key = (min(a, b), max(a, b))
            if key in land:
                continue
            chosen[key] = min(chosen.get(key, 9.0), dist)
    out = []
    for (a, b), chord in chosen.items():
        km = float(chord_to_km(chord))
        weight = 0.3 if km > SEA_RADIUS_KM else round(1.0 - 0.6 * km / SEA_RADIUS_KM, 2)
        out.append((a, b, weight))
    return out


def air_links(feats: list[dict]) -> list[tuple[int, int, float]]:
    act = [f for f in feats if f["active"]]
    hubs = sorted(act, key=lambda f: f["gdp"], reverse=True)[:AIR_HUBS]
    hub_set = {f["index"] for f in hubs}
    links: dict[tuple[int, int], float] = {}

    def nearest(f, pool, k):
        others = [g for g in pool if g["index"] != f["index"]]
        others.sort(key=lambda g: great_circle_km(f["label_lonlat"], g["label_lonlat"]))
        return others[:k]

    for h in hubs:
        for g in nearest(h, hubs, AIR_HUB_NEIGHBORS):
            links[(min(h["index"], g["index"]), max(h["index"], g["index"]))] = 0.4
    for f in act:
        if f["index"] in hub_set or f["population"] < AIR_MIN_POPULATION:
            continue
        for g in nearest(f, hubs, AIR_FEEDERS):
            links.setdefault((min(f["index"], g["index"]), max(f["index"], g["index"])), 0.3)
    return [(a, b, w) for (a, b), w in links.items()]


def climate_of(lat: float) -> str:
    a = abs(lat)
    return "hot" if a < 23.5 else ("temperate" if a < 45.0 else "cold")


def wealth_of(income: str) -> str:
    return {"1": "rich", "2": "rich", "3": "mid"}.get(income[:1], "poor")


COUNTER_WEIGHT = {"rich": 1.6, "mid": 1.0, "poor": 0.6}


# --------------------------------------------------------------------------
def build_relief(tif: Path) -> None:
    out_dir = ROOT / "assets/map/relief"
    out_dir.mkdir(parents=True, exist_ok=True)
    im = Image.open(tif)
    assert im.size == (MAP_W, MAP_H) and im.mode == "L", (im.size, im.mode)
    for row in range(MAP_H // TILE):
        for col in range(MAP_W // TILE):
            path = out_dir / f"relief_{col}_{row}.png"
            print(f"  切图 {path.name}")
            im.crop((col * TILE, row * TILE, (col + 1) * TILE, (row + 1) * TILE)).save(path, optimize=True)


def build_borders(feats: list[dict]) -> list[list[float]]:
    lines = []
    for f in feats:
        for ring in f["rings"]:
            x, y = lonlat_to_px(ring[:, 0], ring[:, 1])
            pts = simplify(np.column_stack([x, y]), BORDER_TOLERANCE)
            for part in split_artificial_edges(pts):
                lines.append([round(float(v), 1) for v in part.ravel()])
    return lines


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-relief", action="store_true", help="不重新切底图")
    args = ap.parse_args()

    feats = load_features(fetch("countries"))
    by_index = {f["index"]: f for f in feats}
    print(f"地区 {len(feats)} 个，参与模拟 {sum(f['active'] for f in feats)} 个")

    if not args.skip_relief:
        build_relief(fetch("relief"))

    print("生成索引图…")
    ids = rasterize_ids(feats)
    (ROOT / "assets/map").mkdir(parents=True, exist_ok=True)
    Image.fromarray(ids, mode="L").save(ROOT / "assets/map/region_ids.png", optimize=True)

    print("计算连接…")
    active_idx = {f["index"] for f in feats if f["active"]}
    code_to_idx = {f["code"]: f["index"] for f in feats}
    not_land = {tuple(sorted((code_to_idx[a], code_to_idx[b]))) for a, b in NOT_LAND}
    land = {k: c for k, c in land_adjacency(ids).items()
            if k[0] in active_idx and k[1] in active_idx and k not in not_land}
    links = []
    for (a, b), count in sorted(land.items()):
        links.append({"a": by_index[a]["code"], "b": by_index[b]["code"], "type": "land",
                      "weight": 1.0 if count >= 40 else 0.6})
    for a, b, w in sorted(sea_links(ids, active_idx, land)):
        links.append({"a": by_index[a]["code"], "b": by_index[b]["code"], "type": "sea", "weight": w})
    for a, b, w in sorted(air_links(feats)):
        links.append({"a": by_index[a]["code"], "b": by_index[b]["code"], "type": "air", "weight": w})
    linked = {l["a"] for l in links} | {l["b"] for l in links}
    isolated = [f["code"] for f in feats if f["active"] and f["code"] not in linked]
    assert not isolated, f"孤立地区: {isolated}"
    print(f"  陆路 {len(land)}，海路 {sum(l['type'] == 'sea' for l in links)}，空路 {sum(l['type'] == 'air' for l in links)}")

    print("生成边界线…")
    borders = build_borders(feats)
    print(f"  {len(borders)} 条折线，{sum(len(b) for b in borders) // 2} 个点")

    regions_meta = []
    for f in feats:
        lx, ly = lonlat_to_px(*f["label_lonlat"])
        allp = np.vstack(f["rings"])
        bx0, by0 = lonlat_to_px(allp[:, 0].min(), allp[:, 1].max())
        bx1, by1 = lonlat_to_px(allp[:, 0].max(), allp[:, 1].min())
        regions_meta.append({
            "index": f["index"], "id": f["code"], "name": f["name"], "name_en": f["name_en"],
            "active": f["active"], "labelrank": f["labelrank"],
            "label": [round(float(lx), 1), round(float(ly), 1)],
            "bbox": [round(float(v), 1) for v in (bx0, by0, bx1, by1)],
        })
    map_json = {
        "source": "Natural Earth 10m (public domain), admin_0_countries_chn + GRAY_HR_SR_OB_DR",
        "size": [MAP_W, MAP_H],
        "px_per_degree": PX_PER_DEG,
        "relief": {"pattern": "res://assets/map/relief/relief_%d_%d.png", "tile": TILE,
                   "cols": MAP_W // TILE, "rows": MAP_H // TILE},
        "region_ids": {"path": "res://assets/map/region_ids.png", "scale": ID_SCALE},
        "regions": regions_meta,
        "borders": borders,
    }
    (ROOT / "data/map").mkdir(parents=True, exist_ok=True)
    (ROOT / "data/map/world_map.json").write_text(json.dumps(map_json, ensure_ascii=False, separators=(",", ":")))

    scen_path = ROOT / "data/scenarios/world.json"
    old = json.loads(scen_path.read_text()) if scen_path.exists() else {}
    defaults = json.loads((Path(__file__).parent / "world_rules_default.json").read_text())
    scenario = {
        "id": "world",
        "name": old.get("name", "真实世界"),
        "map": "res://data/map/world_map.json",
        "labels": old.get("labels", defaults["labels"]),
        "rules": old.get("rules", defaults["rules"]),
        "regions": [
            {"id": f["code"], "name": f["name"], "population": int(f["population"]),
             "counter_weight": COUNTER_WEIGHT[wealth_of(f["income"])],
             "traits": {"climate": climate_of(f["label_lonlat"][1]), "wealth": wealth_of(f["income"])}}
            for f in feats if f["active"]
        ],
        "links": links,
    }
    scen_path.write_text(json.dumps(scenario, ensure_ascii=False, indent=1))
    print("完成。")


if __name__ == "__main__":
    main()
