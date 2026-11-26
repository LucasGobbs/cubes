#!/usr/bin/env python3
"""Converte os pacotes Quaternius (CC0) em GLBs skinned que a engine carrega.

Uso:
  python3 tools/prep_skinned_glb.py --ual "assets/UAL.zip/UAL1_Standard.glb" --character "assets/Base.zip/Superhero_Male_FullBody.gltf" --out static/models/superhero_male.glb
  python3 tools/prep_skinned_glb.py --ual "assets/UAL.zip/UAL1_Standard.glb" --out static/models/mannequin.glb

Sem --character gera o Mannequin do próprio UAL (malha cinza, sem textura).

Regras que a engine impõe (src/engine/gfx/loader/model.odin, skin.odin):
- só o primeiro skin é importado; só nós com mesh + skin entram na malha;
- uma textura por modelo (atlas): body, cabelo e olhos num único PNG 2048x2048;
- animações são lidas por nome de clip; canais cubic-spline são ignorados.

Animações: o UAL é transplantado por NOME de osso. Canais são reescritos como delta
sobre a pose de repouso do UAL e aplicados sobre a pose de repouso do personagem,
então diferenças de repouso entre os rigs não deformam a malha. Canais constantes
iguais ao repouso do personagem são removidos (a engine usa o repouso por padrão).
"""

import argparse
import io
import json
import os
import struct
import tempfile
import zipfile

import numpy as np
from PIL import Image

CLIPS = [
    "Idle_Loop", "Walk_Loop", "Jog_Fwd_Loop", "Sprint_Loop",
    "Jump_Start", "Jump_Loop", "Jump_Land",
    "Crouch_Idle_Loop", "Crouch_Fwd_Loop", "Sitting_Idle_Loop",
    "Punch_Jab", "Punch_Cross", "Sword_Attack", "Pistol_Shoot",
    "Hit_Chest", "Death01", "Dance_Loop", "Roll",
]

ATLAS = 2048
# Regiões do atlas em pixels (x0, y0, w, h); body e cabelo 1024, olhos 256.
REGIONS = {
    "body": (0, 0, 1024, 1024),
    "hair": (1024, 0, 1024, 1024),
    "eyes": (0, 1024, 256, 256),
}
# UVs dos olhos passam de 1 (1.215): a região guarda 2x2 cópias da textura.
TILES = {"body": (1, 1), "hair": (1, 1), "eyes": (2, 2)}

# Cor do cabelo, barba e sobrancelhas (região hair; T_Hair_N é cinza). Multiplicada no atlas, sRGB 0..1.
HAIR_TINT = {
    "Superhero_Male_FullBody.gltf": (0.30, 0.19, 0.11),    # castanho escuro
    "Superhero_Female_FullBody.gltf": (0.78, 0.60, 0.28),  # loiro-dourado
}
# Mannequin: a engine ignora baseColorFactor no skin, então o cinza vai na textura 1x1 (sRGB 0..1).
MANNEQUIN_GREY = 0.35

DT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
F32 = np.float32


class Gltf:
    def __init__(self, path):
        self.dir = os.path.dirname(os.path.abspath(path))
        data = open(path, "rb").read()
        self.bin = None
        if data[:4] == b"glTF":
            jl = struct.unpack_from("<I", data, 12)[0]
            self.j = json.loads(data[20:20 + jl])
            off = 20 + jl
            if off + 8 <= len(data):
                bl = struct.unpack_from("<I", data, off)[0]
                self.bin = data[off + 8: off + 8 + bl]
        else:
            self.j = json.loads(data)
        self.buffers = [
            open(os.path.join(self.dir, b["uri"]), "rb").read() if "uri" in b else self.bin
            for b in self.j.get("buffers", [])
        ]

    def accessor(self, i):
        a = self.j["accessors"][i]
        assert "sparse" not in a, "accessor esparso não suportado"
        dt = np.dtype(DT[a["componentType"]]).newbyteorder("<")
        nc = NC[a["type"]]
        bv = self.j["bufferViews"][a["bufferView"]]
        stride = bv.get("byteStride", dt.itemsize * nc)
        start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        arr = np.ndarray((a["count"], nc), dtype=dt, buffer=self.buffers[bv["buffer"]], offset=start, strides=(stride, dt.itemsize))
        return arr.astype(dt.newbyteorder("=")).copy()

    def image_path(self, mat_name, slot):
        mat = next(m for m in self.j["materials"] if m["name"] == mat_name)
        tex = self.j["textures"][mat["pbrMetallicRoughness"][slot]["index"]]
        return os.path.join(self.dir, self.j["images"][tex["source"]]["uri"])


def rest_trs(node):
    assert "matrix" not in node, "nó com matrix não suportado"
    return (
        np.array(node.get("translation", [0, 0, 0]), dtype=np.float64),
        np.array(node.get("rotation", [0, 0, 0, 1]), dtype=np.float64),
        np.array(node.get("scale", [1, 1, 1]), dtype=np.float64),
    )


def qmul(a, b):
    ax, ay, az, aw = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    bx, by, bz, bw = b[..., 0], b[..., 1], b[..., 2], b[..., 3]
    return np.stack([
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    ], axis=-1)


def qconj(q):
    return q * np.array([-1, -1, -1, 1.0])


def qnorm(q):
    return q / np.linalg.norm(q, axis=-1, keepdims=True)


def world_matrices(j):
    """Matriz mundo de repouso de todo nó, a partir das raízes da cena."""
    parent = {}
    for i, n in enumerate(j["nodes"]):
        for c in n.get("children", []):
            parent[c] = i
    world = {}

    def local(i):
        t, r, s = rest_trs(j["nodes"][i])
        m = np.eye(4)
        x, y, z, w = r / np.linalg.norm(r)
        m[:3, :3] = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]) @ np.diag(s)
        m[:3, 3] = t
        return m

    def visit(i, acc):
        m = acc @ local(i)
        world[i] = m
        for c in j["nodes"][i].get("children", []):
            visit(c, m)

    for root in j["scenes"][j.get("scene", 0)]["nodes"]:
        visit(root, np.eye(4))
    return world


class Out:
    """Monta o BIN e o JSON do GLB de saída."""

    def __init__(self):
        self.bin = bytearray()
        self.views = []
        self.accessors = []

    def view(self, data, target=None):
        while len(self.bin) % 4:
            self.bin.append(0)
        off = len(self.bin)
        self.bin += data
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            v["target"] = target
        self.views.append(v)
        return len(self.views) - 1

    def accessor(self, arr, ctype, typ, target=None):
        arr = np.ascontiguousarray(arr, dtype=np.dtype(DT[ctype]).newbyteorder("<"))
        acc = {"bufferView": self.view(arr.tobytes(), target), "componentType": ctype, "count": arr.shape[0], "type": typ}
        if typ == "VEC3" or typ == "SCALAR" or ctype == 5126:
            if arr.ndim == 2 and arr.shape[1] > 0 and typ in ("VEC3", "VEC2", "VEC4"):
                acc["min"] = [float(x) for x in arr.min(axis=0)]
                acc["max"] = [float(x) for x in arr.max(axis=0)]
            elif typ == "SCALAR" and arr.size:
                acc["min"] = [float(arr.min())]
                acc["max"] = [float(arr.max())]
        self.accessors.append(acc)
        return len(self.accessors) - 1

    def glb(self, doc):
        doc["buffers"] = [{"byteLength": len(self.bin)}]
        doc["bufferViews"] = self.views
        doc["accessors"] = self.accessors
        js = json.dumps(doc, separators=(",", ":")).encode()
        js += b" " * ((4 - len(js) % 4) % 4)
        binc = bytes(self.bin) + b"\0" * ((4 - len(self.bin) % 4) % 4)
        total = 12 + 8 + len(js) + 8 + len(binc)
        return (struct.pack("<4sII", b"glTF", 2, total)
                + struct.pack("<I4s", len(js), b"JSON") + js
                + struct.pack("<I4s", len(binc), b"BIN\0") + binc)


def region_of(mat_name):
    if mat_name.startswith("MI_Hair"):
        return "hair"
    if mat_name == "MI_Eyes":
        return "eyes"
    if mat_name.startswith("MI_Superhero"):
        return "body"
    raise ValueError(f"material não mapeado para o atlas: {mat_name}")


def skinned_prims(g, textured):
    """Primitivas triangulares de todo nó com mesh + skin, em ordem de nó."""
    prims = []
    for ni, node in enumerate(g.j["nodes"]):
        if "mesh" not in node or node.get("skin") is None:
            continue
        for p in g.j["meshes"][node["mesh"]]["primitives"]:
            assert p.get("mode", 4) == 4, "primitiva não-triângulo"
            a = p["attributes"]
            mat = g.j["materials"][p["material"]]["name"] if "material" in p else None
            region = region_of(mat) if textured else None
            uv = g.accessor(a["TEXCOORD_0"]).astype(np.float64) if textured else None
            if textured:
                lim = np.array(TILES[region_of(mat)], dtype=np.float64)
                assert uv.min() >= -1e-4 and (uv.max(axis=0) <= lim + 1e-4).all(), f"UV {uv.min(0)}..{uv.max(0)} em {mat} fora de {lim}"
            prims.append({
                "mat": mat,
                "region": region,
                "pos": g.accessor(a["POSITION"]).astype(F32),
                "nrm": g.accessor(a["NORMAL"]).astype(F32),
                "uv": uv,
                "jnt": g.accessor(a["JOINTS_0"]),
                "wgt": g.accessor(a["WEIGHTS_0"]).astype(F32),
                "idx": g.accessor(p["indices"]).reshape(-1).astype(np.int64),
            })
    assert prims, "nenhuma primitiva skinned encontrada"
    return prims


def tint_rgb(img, color):
    a = np.asarray(img).astype(np.float32)
    a[..., :3] = np.clip(a[..., :3] * np.array(color, np.float32) + 0.5, 0, 255)
    return Image.fromarray(a.astype(np.uint8))


def solid_png(grey):
    buf = io.BytesIO()
    v = round(grey * 255)
    Image.new("RGBA", (1, 1), (v, v, v, 255)).save(buf, format="PNG")
    return buf.getvalue()


def build_atlas(g, prims, hair_tint):
    atlas = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
    seen = {}
    for p in prims:
        if p["region"] is None or p["region"] in seen:
            continue
        x0, y0, w, h = REGIONS[p["region"]]
        img = Image.open(g.image_path(p["mat"], "baseColorTexture")).convert("RGBA")
        if img.size != (w, h):
            img = img.resize((w, h), Image.LANCZOS)
        if p["region"] == "hair":
            img = tint_rgb(img, hair_tint)
        tx, ty = TILES[p["region"]]
        for i in range(tx):
            for j in range(ty):
                atlas.paste(img, (x0 + i * w, y0 + j * h))
        seen[p["region"]] = p["mat"]
    buf = io.BytesIO()
    atlas.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def merge_mesh(out, prims, textured):
    pos, nrm, uv, jnt, wgt, idx = [], [], [], [], [], []
    base = 0
    for p in prims:
        n = p["pos"].shape[0]
        assert p["jnt"].max() < 256, "JOINTS_0 acima de u8"
        if textured:
            x0, y0, w, h = REGIONS[p["region"]]
            t = np.empty_like(p["uv"])
            t[:, 0] = (x0 + p["uv"][:, 0] * w) / ATLAS
            t[:, 1] = (y0 + p["uv"][:, 1] * h) / ATLAS
            uv.append(t.astype(F32))
        pos.append(p["pos"]); nrm.append(p["nrm"]); jnt.append(p["jnt"].astype(np.uint8)); wgt.append(p["wgt"])
        idx.append(p["idx"] + base)
        base += n
    pos = np.concatenate(pos); idx = np.concatenate(idx)
    attrs = {
        "POSITION": out.accessor(pos, 5126, "VEC3", 34962),
        "NORMAL": out.accessor(np.concatenate(nrm), 5126, "VEC3", 34962),
        "JOINTS_0": out.accessor(np.concatenate(jnt), 5121, "VEC4", 34962),
        "WEIGHTS_0": out.accessor(np.concatenate(wgt), 5126, "VEC4", 34962),
    }
    if textured:
        attrs["TEXCOORD_0"] = out.accessor(np.concatenate(uv), 5126, "VEC2", 34962)
    ctype = 5123 if base <= 65535 else 5125
    ind = out.accessor(idx.astype(DT[ctype]), ctype, "SCALAR", 34963)
    return attrs, ind


def retarget(src, dst, clip_names, rest_src, rest_dst):
    """Reescreve canais do UAL como delta sobre o repouso do destino."""
    clips = []
    kept = dropped = 0
    for name in clip_names:
        anim = next(a for a in src.j["animations"] if a["name"] == name)
        channels = []
        for ch in anim["channels"]:
            bone = src.j["nodes"][ch["target"]["node"]]["name"]
            if bone not in rest_dst:
                continue
            path = ch["target"]["path"]
            smp = anim["samplers"][ch["sampler"]]
            times = src.accessor(smp["input"]).reshape(-1).astype(F32)
            vals = src.accessor(smp["output"]).astype(np.float64)
            rs_t, rs_r, rs_s = rest_src[bone]
            rd_t, rd_r, rd_s = rest_dst[bone]
            if path == "translation":
                out = rd_t + (vals - rs_t)
                rest = rd_t
                ok = np.abs(out - rest).max() < 1e-6
            elif path == "scale":
                out = rd_s * vals / rs_s
                rest = rd_s
                ok = np.abs(out - rest).max() < 1e-6
            else:
                out = qnorm(qmul(rd_r, qmul(qconj(rs_r), vals)))
                flip = np.sum(out * vals, axis=-1) < 0
                out[flip] *= -1
                rest = rd_r
                ok = np.abs(np.abs(out @ rest) - 1).max() < 1e-7
            if ok:
                dropped += 1
                continue
            kept += 1
            channels.append((bone, path, times, out.astype(F32)))
        clips.append((name, channels))
    return clips, kept, dropped


def add_animations(out, clips, dst_by_name):
    anims = []
    time_cache = {}
    for name, channels in clips:
        samplers, chans = [], []
        for bone, path, times, vals in channels:
            key = times.tobytes()
            if key not in time_cache:
                time_cache[key] = out.accessor(times, 5126, "SCALAR")
            typ = "VEC4" if path == "rotation" else "VEC3"
            samplers.append({"input": time_cache[key], "output": out.accessor(vals, 5126, typ), "interpolation": "LINEAR"})
            chans.append({"sampler": len(samplers) - 1, "target": {"node": dst_by_name[bone], "path": path}})
        anims.append({"name": name, "channels": chans, "samplers": samplers})
    return anims


def rest_report(src, dst, rest_src, rest_dst):
    worst_rot = max((2 * np.arccos(min(1.0, abs(float(rest_src[b][1] @ rest_dst[b][1])))), b) for b in rest_dst if b in rest_src)
    worst_pos = max((float(np.linalg.norm(rest_src[b][0] - rest_dst[b][0])), b) for b in rest_dst if b in rest_src)
    print(f"  repouso: maior diff de rotação {np.degrees(worst_rot[0]):.2f}° ({worst_rot[1]}), maior diff de translação {worst_pos[0]:.4f} ({worst_pos[1]})")
    wd = world_matrices(dst.j)
    ws = world_matrices(src.j)
    skin = dst.j["skins"][0]
    ibm = dst.accessor(skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
    err = max(float(np.abs(np.linalg.inv(ibm[k]) - wd[j]).max()) for k, j in enumerate(skin["joints"]))
    print(f"  IBM: max |inv(IBM) - mundo de repouso| = {err:.2e}")
    return ws


def resolve_input(path):
    """Aceita arquivo extraído ou `pacote.zip/<caminho final>`: extrai o zip em tmp; o caminho final tem que casar um único arquivo."""
    if ".zip/" not in path:
        return path
    zip_path, member = path.split(".zip/", 1)
    dst = tempfile.mkdtemp(prefix="quaternius_")
    with zipfile.ZipFile(zip_path + ".zip") as z:
        z.extractall(dst)
    hits = []
    for root, _, files in os.walk(dst):
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), dst)
            if rel == member or rel.endswith(os.sep + member):
                hits.append(os.path.join(root, f))
    if len(hits) != 1:
        raise FileNotFoundError(f"{member}: {len(hits)} correspondências em {zip_path}.zip")
    return hits[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ual", required=True, help="UAL1_Standard.glb (sem root motion)")
    ap.add_argument("--character", help="Superhero_*_FullBody.gltf; omitir gera o Mannequin do UAL")
    ap.add_argument("--hair", action="append", default=[], help="Hair_*.gltf (Rigged to Head Bone); repetível")
    ap.add_argument("--out", required=True)
    ap.add_argument("--clips", default=",".join(CLIPS))
    args = ap.parse_args()
    clip_names = args.clips.split(",")

    ual = Gltf(resolve_input(args.ual))
    char = Gltf(resolve_input(args.character)) if args.character else None
    dst = char or ual
    textured = char is not None

    skin_joints = dst.j["skins"][0]["joints"]
    assert ual.j["skins"][0]["joints"] and len(skin_joints) == len(ual.j["skins"][0]["joints"])
    rest_src = {ual.j["nodes"][j]["name"]: rest_trs(ual.j["nodes"][j]) for j in ual.j["skins"][0]["joints"]}
    rest_dst = {dst.j["nodes"][j]["name"]: rest_trs(dst.j["nodes"][j]) for j in skin_joints}
    assert set(rest_src) == set(rest_dst), "nomes de osso diferem entre UAL e personagem"

    print(f"{os.path.basename(args.out)}: {len(skin_joints)} ossos, {len(clip_names)} clips")
    if char:
        rest_report(ual, char, rest_src, rest_dst)

    prims = skinned_prims(dst, textured)
    for h in args.hair:
        hg = Gltf(resolve_input(h))
        assert [hg.j["nodes"][j]["name"] for j in hg.j["skins"][0]["joints"]] == [dst.j["nodes"][j]["name"] for j in skin_joints], "ossos do penteado diferem do personagem"
        prims += skinned_prims(hg, textured)
    out = Out()
    attrs, ind = merge_mesh(out, prims, textured)
    material = {
        "name": "Atlas" if textured else "Mannequin",
        "doubleSided": True,
        "pbrMetallicRoughness": {"metallicFactor": 0, "roughnessFactor": 0.8},
    }
    doc = {"asset": {"version": "2.0", "generator": "tools/prep_skinned_glb.py",
                     "copyright": "Quaternius, CC0 1.0 Universal"}}
    images = []
    if textured:
        png = build_atlas(dst, prims, HAIR_TINT[os.path.basename(args.character)])
    else:
        png = solid_png(MANNEQUIN_GREY)
    images.append({"mimeType": "image/png", "bufferView": out.view(png)})
    material["pbrMetallicRoughness"]["baseColorTexture"] = {"index": 0}
    doc["textures"] = [{"source": 0, "sampler": 0}]
    doc["samplers"] = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
    doc["images"] = images
    doc["materials"] = [material]

    clips, kept, dropped = retarget(ual, dst, clip_names, rest_src, rest_dst)
    dst_by_name = {dst.j["nodes"][j]["name"]: j for j in skin_joints}
    anims = add_animations(out, clips, dst_by_name)
    ibm = out.accessor(dst.accessor(dst.j["skins"][0]["inverseBindMatrices"]).astype(F32), 5126, "MAT4")

    nodes = [dict(n) for n in dst.j["nodes"]]
    for n in nodes:
        n.pop("mesh", None)
        n.pop("skin", None)
    nodes.append({"name": "Mesh", "mesh": 0, "skin": 0})
    scene_nodes = list(dst.j["scenes"][dst.j.get("scene", 0)]["nodes"]) + [len(nodes) - 1]

    doc.update({
        "scene": 0,
        "scenes": [{"nodes": scene_nodes}],
        "nodes": nodes,
        "meshes": [{"name": "Body", "primitives": [{"attributes": attrs, "indices": ind, "material": 0}]}],
        "skins": [{"name": "Armature", "joints": skin_joints, "inverseBindMatrices": ibm}],
        "animations": anims,
    })
    data = out.glb(doc)
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"  texturas: {'atlas 2048 PNG' if textured else 'nenhuma (cor base cinza)'}; canais mantidos {kept}, removidos {dropped}; {len(data) / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
