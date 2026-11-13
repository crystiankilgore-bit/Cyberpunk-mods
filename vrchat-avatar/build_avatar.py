"""
NEON-7 - a cyberpunk android avatar for VRChat, built entirely from code.

Run:  python3 build_avatar.py            (needs `pip install bpy`, Blender 4.2+ / 5.x)
      python3 build_avatar.py --no-render (skip the preview renders)

Outputs (in ./output):
  NEON-7.fbx            rigged mesh for Unity (humanoid bone names, visemes, blink)
  NEON-7.blend          editable Blender file
  textures/*.png        palette textures (albedo, emission, metallic/smoothness)
  previews/*.png        Cycles renders

Everything is one mesh ("Body"), one material, three 128px textures.
Recolor it by editing PALETTE below and re-running.
"""
import math
import os
import sys

import bpy  # must come before bmesh/mathutils
import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "output")
NAME = "NEON-7"
RENDER = "--no-render" not in sys.argv

# --------------------------------------------------------------------------
# Palette: name -> (albedo sRGB, emission sRGB, metallic, smoothness)
# --------------------------------------------------------------------------
PALETTE = {
    "suit":     ((0.060, 0.064, 0.080), (0, 0, 0), 0.15, 0.45),
    "armor":    ((0.840, 0.850, 0.880), (0, 0, 0), 0.05, 0.72),
    "chrome":   ((0.600, 0.610, 0.650), (0, 0, 0), 1.00, 0.85),
    "gunmetal": ((0.130, 0.130, 0.150), (0, 0, 0), 0.90, 0.60),
    "cyan":     ((0.000, 0.900, 1.000), (0.00, 0.90, 1.00), 0.0, 0.80),
    "magenta":  ((1.000, 0.080, 0.600), (1.00, 0.08, 0.60), 0.0, 0.80),
    "yellow":   ((0.980, 0.820, 0.050), (0, 0, 0), 0.30, 0.60),
    "visor":    ((0.010, 0.010, 0.016), (0, 0, 0), 0.50, 0.97),
    "rubber":   ((0.025, 0.025, 0.028), (0, 0, 0), 0.00, 0.20),
}
ORDER = list(PALETTE)
GRID, CELL = 4, 32
TEX = GRID * CELL


def uv_of(color):
    i = ORDER.index(color)
    return ((i % GRID + 0.5) / GRID, (i // GRID + 0.5) / GRID)


# --------------------------------------------------------------------------
# Skeleton (Unity HumanBodyBones names). Blender: Z up, character faces -Y,
# character's left is +X. Rest pose is a T-pose.
# --------------------------------------------------------------------------
BONES = []


def B(name, head, tail, parent):
    BONES.append((name, Vector(head), Vector(tail), parent))


ARM_Z = 1.41
B("Hips", (0, 0, 0.93), (0, 0, 1.03), None)
B("Spine", (0, 0, 1.03), (0, 0, 1.16), "Hips")
B("Chest", (0, 0, 1.16), (0, 0, 1.30), "Spine")
B("UpperChest", (0, 0, 1.30), (0, 0, 1.45), "Chest")
B("Neck", (0, 0, 1.45), (0, 0, 1.56), "UpperChest")
B("Head", (0, 0, 1.56), (0, 0, 1.80), "Neck")

FINGERS = {  # name: (y offset, segment lengths, radius)
    "Index":  (-0.030, (0.032, 0.022, 0.018), 0.0085),
    "Middle": (-0.010, (0.035, 0.024, 0.019), 0.0088),
    "Ring":   (0.010, (0.032, 0.022, 0.018), 0.0083),
    "Little": (0.029, (0.025, 0.017, 0.015), 0.0072),
}
THUMB = [(0.695, -0.030, 1.402), (0.725, -0.058, 1.398), (0.750, -0.072, 1.395), (0.772, -0.080, 1.393)]
SEGS = ("Proximal", "Intermediate", "Distal")

for s, side in ((1, "Left"), (-1, "Right")):
    B(side + "Eye", (s * 0.012, -0.02, 1.688), (s * 0.012, -0.02, 1.718), "Head")
    B(side + "UpperLeg", (s * 0.095, 0, 0.90), (s * 0.10, 0, 0.51), "Hips")
    B(side + "LowerLeg", (s * 0.10, 0, 0.51), (s * 0.10, 0.01, 0.09), side + "UpperLeg")
    B(side + "Foot", (s * 0.10, 0.01, 0.09), (s * 0.10, -0.10, 0.03), side + "LowerLeg")
    B(side + "Toes", (s * 0.10, -0.10, 0.03), (s * 0.10, -0.16, 0.03), side + "Foot")
    B(side + "Shoulder", (s * 0.03, 0, ARM_Z), (s * 0.17, 0, ARM_Z), "UpperChest")
    B(side + "UpperArm", (s * 0.17, 0, ARM_Z), (s * 0.43, 0, ARM_Z), side + "Shoulder")
    B(side + "LowerArm", (s * 0.43, 0, ARM_Z), (s * 0.68, 0, ARM_Z), side + "UpperArm")
    B(side + "Hand", (s * 0.68, 0, ARM_Z), (s * 0.775, 0, ARM_Z), side + "LowerArm")
    for f, (y, lens, _r) in FINGERS.items():
        x, parent = 0.775, side + "Hand"
        for seg, L in zip(SEGS, lens):
            n = side + f + seg
            B(n, (s * x, y, ARM_Z), (s * (x + L), y, ARM_Z), parent)
            parent, x = n, x + L
    parent = side + "Hand"
    for seg, a, b in zip(SEGS, THUMB, THUMB[1:]):
        n = side + "Thumb" + seg
        B(n, (s * a[0], a[1], a[2]), (s * b[0], b[1], b[2]), parent)
        parent = n

BONE_INDEX = {b[0]: i for i, b in enumerate(BONES)}
BONE_SEG = {b[0]: (b[1], b[2]) for b in BONES}

# --------------------------------------------------------------------------
# Geometry helpers: everything goes into one bmesh.
# --------------------------------------------------------------------------
BM = bmesh.new()
UVL = BM.loops.layers.uv.verify()
DEF = BM.verts.layers.deform.verify()
TAGS, TAGINFO = {}, {}
I4 = Matrix.Identity(4)


def V(*a):
    return Vector(a[0] if len(a) == 1 else a)


def frame(z):
    z = z.normalized()
    ref = Vector((1, 0, 0)) if abs(z.x) < 0.9 else Vector((0, 1, 0))
    x = (ref - z * ref.dot(z)).normalized()
    return x, z.cross(x), z


def segdist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
    return (p - (a + ab * t)).length


def weight(verts, bones):
    if isinstance(bones, str):
        gi = BONE_INDEX[bones]
        for v in verts:
            v[DEF][gi] = 1.0
        return
    for v in verts:
        ws = sorted(((1.0 / max(segdist(v.co, *BONE_SEG[b]), 1e-4) ** 6, b) for b in bones), reverse=True)[:3]
        tot = sum(w for w, _ in ws)
        ws = [(w / tot, b) for w, b in ws if w / tot > 0.01]
        tot = sum(w for w, _ in ws)
        for w, b in ws:
            v[DEF][BONE_INDEX[b]] = w / tot


def fin(verts, color, bones, smooth=True, tag=None, recalc=True):
    verts = [v for v in verts if v.is_valid]
    faces = list({f for v in verts for f in v.link_faces})
    if recalc:
        bmesh.ops.recalc_face_normals(BM, faces=faces)
    uv = uv_of(color)
    for f in faces:
        f.smooth = smooth
        for l in f.loops:
            l[UVL].uv = uv
    weight(verts, bones)
    if tag:
        TAGS.setdefault(tag, []).extend(verts)
    return verts


def loft(p0, p1, prof, color, bones, seg=16, **kw):
    """Tube from p0 to p1; prof = [(t, rx, ry), ...] elliptical rings, capped."""
    p0, p1 = V(p0), V(p1)
    d = p1 - p0
    x, y, _ = frame(d)
    rings = []
    for t, rx, ry in prof:
        c = p0 + d * t
        rings.append([BM.verts.new(c + x * math.cos(a) * rx + y * math.sin(a) * ry)
                      for a in (2 * math.pi * i / seg for i in range(seg))])
    for r0, r1 in zip(rings, rings[1:]):
        for i in range(seg):
            j = (i + 1) % seg
            BM.faces.new((r0[i], r0[j], r1[j], r1[i]))
    a, b = BM.verts.new(p0 + d * prof[0][0]), BM.verts.new(p0 + d * prof[-1][0])
    for i in range(seg):
        j = (i + 1) % seg
        BM.faces.new((a, rings[0][j], rings[0][i]))
        BM.faces.new((b, rings[-1][i], rings[-1][j]))
    return fin([v for r in rings for v in r] + [a, b], color, bones, **kw)


def capsule(p0, p1, r, color, bones, seg=8, **kw):
    return loft(p0, p1, [(0, r * .6, r * .6), (.15, r, r), (.85, r, r), (1, r * .6, r * .6)], color, bones, seg, **kw)


def tube(pts, r, color, bones):
    out = []
    for a, b in zip(pts, pts[1:]):
        out += capsule(a, b, r, color, bones, seg=8)
    return out


def sphere(c, r, color, bones, scale=(1, 1, 1), seg=16, rings=8, rot=I4, **kw):
    m = Matrix.Translation(V(c)) @ rot @ Matrix.Diagonal((*scale, 1))
    res = bmesh.ops.create_uvsphere(BM, u_segments=seg, v_segments=rings, radius=r, matrix=m)
    return fin(res["verts"], color, bones, **kw)


def shell(c, scale, keep, color, bones, thick=0.006, seg=28, rings=14):
    """Section of an ellipsoid (faces where keep(normal, center) is true), given thickness."""
    m = Matrix.Translation(V(c)) @ Matrix.Diagonal((*scale, 1))
    verts = bmesh.ops.create_uvsphere(BM, u_segments=seg, v_segments=rings, radius=1.0, matrix=m)["verts"]
    faces = list({f for v in verts for f in v.link_faces})
    bmesh.ops.recalc_face_normals(BM, faces=faces)
    for f in faces:
        f.normal_update()
    bmesh.ops.delete(BM, geom=[f for f in faces if not keep(f.normal, f.calc_center_median())], context="FACES")
    verts = [v for v in verts if v.is_valid]
    faces = list({f for v in verts for f in v.link_faces})
    res = bmesh.ops.solidify(BM, geom=faces, thickness=thick)
    verts += [g for g in res["geom"] if isinstance(g, bmesh.types.BMVert)]
    return fin(verts, color, bones)


def torus(c, axis, R, r, color, bones, Ry=None, seg=28, sseg=8):
    c = V(c)
    x, y, z = frame(V(axis))
    Ry = Ry or R
    rings = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        off = x * math.cos(a) * R + y * math.sin(a) * Ry
        rad = off.normalized()
        rings.append([BM.verts.new(c + off + rad * math.cos(b) * r + z * math.sin(b) * r)
                      for b in (2 * math.pi * k / sseg for k in range(sseg))])
    for i in range(seg):
        r0, r1 = rings[i], rings[(i + 1) % seg]
        for k in range(sseg):
            j = (k + 1) % sseg
            BM.faces.new((r0[k], r0[j], r1[j], r1[k]))
    return fin([v for rg in rings for v in rg], color, bones)


def box(c, size, color, bones, rot=I4, bevel=0.0, pre=I4):
    m = Matrix.Translation(V(c)) @ rot @ pre @ Matrix.Diagonal((*size, 1))
    verts = bmesh.ops.create_cube(BM, size=1.0, matrix=m)["verts"]
    if bevel:
        edges = list({e for v in verts for e in v.link_edges})
        res = bmesh.ops.bevel(BM, geom=edges + verts, offset=bevel, segments=2, profile=0.5, affect="EDGES")
        verts = [v for v in verts if v.is_valid] + list(res["verts"])
    return fin(verts, color, bones, smooth=False)


def cylinder(c, axis, r, depth, color, bones, seg=20):
    _, _, z = frame(V(axis))
    rot = Vector((0, 0, 1)).rotation_difference(z).to_matrix().to_4x4()
    m = Matrix.Translation(V(c)) @ rot
    verts = bmesh.ops.create_cone(BM, cap_ends=True, cap_tris=False, segments=seg,
                                  radius1=r, radius2=r, depth=depth, matrix=m)["verts"]
    return fin(verts, color, bones, smooth=False)


def hit(origin, direction, offset=0.0):
    BM.normal_update()
    tree = BVHTree.FromBMesh(BM)
    loc, n, _, _ = tree.ray_cast(V(origin), V(direction).normalized())
    if loc is None:
        raise RuntimeError(f"raycast missed: {origin} {direction}")
    return loc + n * offset, n


def facing(n):
    """Rotation turning local -Y (the 'front') onto normal n."""
    return Vector((0, -1, 0)).rotation_difference(n).to_matrix().to_4x4()


def surface_line(pts2d, axis, offset=0.003):
    """Project 2D points onto the surface from the given side. axis: '-y' front, '+y' back, 'x+'/'x-' side, 'z' top."""
    out = []
    for p in pts2d:
        if axis == "-y":
            loc, _ = hit((p[0], -0.8, p[1]), (0, 1, 0), offset)
        elif axis == "+y":
            loc, _ = hit((p[0], 0.8, p[1]), (0, -1, 0), offset)
        elif axis in ("x+", "x-"):
            s = 1 if axis == "x+" else -1
            loc, _ = hit((s * 0.8, p[0], p[1]), (-s, 0, 0), offset)
        else:  # top
            loc, _ = hit((p[0], p[1], 2.5), (0, 0, -1), offset)
        out.append(loc)
    return out


# --------------------------------------------------------------------------
# Build the body
# --------------------------------------------------------------------------
def build_head():
    loft((0, -0.005, 1.552), (0, -0.005, 1.815),
         [(0, .025, .025), (.03, .055, .062), (.07, .07, .08), (.14, .08, .094), (.25, .088, .104),
          (.38, .095, .112), (.5, .099, .117), (.62, .099, .117), (.75, .095, .112), (.85, .085, .101),
          (.92, .07, .085), (.97, .045, .055), (1, .015, .015)], "armor", "Head", seg=36)
    shell((0, -0.01, 1.688), (0.104, 0.121, 0.046), lambda n, c: n.y < -0.35, "visor", "Head", thick=0.004, seg=48, rings=24)

    for s, tag in ((1, "eyeL"), (-1, "eyeR")):
        c, n = hit((s * 0.037, -0.8, 1.690), (0, 1, 0), 0.0012)
        rot = facing(n) @ Matrix.Rotation(math.radians(-s * 7), 4, "Y")
        sphere(c, 1.0, "cyan", ("Left" if s > 0 else "Right") + "Eye", scale=(0.020, 0.003, 0.0085),
               seg=20, rings=8, rot=rot, tag=tag)
        TAGINFO[tag] = (c.copy(), (rot @ Vector((1, 0, 0, 0))).xyz, (rot @ Vector((0, 0, 1, 0))).xyz, s)

    c, n = hit((0, -0.8, 1.612), (0, 1, 0), 0.0012)
    rot = facing(n)
    sphere(c, 1.0, "cyan", "Head", scale=(0.017, 0.003, 0.0026), seg=20, rings=8, rot=rot, tag="mouth")
    TAGINFO["mouth"] = (c.copy(), Vector((1, 0, 0)), (rot @ Vector((0, 0, 1, 0))).xyz, 0)

    # cheek vents
    for s in (1, -1):
        for dz in (0.0, -0.01):
            tube(surface_line([(s * 0.055, 1.628 + dz), (s * 0.075, 1.622 + dz)], "-y", 0.001), 0.0022, "magenta", "Head")

    # ear pods + antenna
    for s in (1, -1):
        cylinder((s * 0.097, 0.005, 1.68), (1, 0, 0), 0.034, 0.036, "gunmetal", "Head")
        torus((s * 0.116, 0.005, 1.68), (1, 0, 0), 0.025, 0.004, "cyan", "Head", seg=24, sseg=6)
        sphere((s * 0.116, 0.005, 1.68), 0.012, "magenta", "Head", scale=(0.4, 1, 1))
    tube([(0.11, 0.02, 1.70), (0.12, 0.05, 1.88)], 0.0035, "chrome", "Head")
    sphere((0.12, 0.05, 1.885), 0.009, "magenta", "Head")

    # neon crest
    for y, h in zip((-0.075, -0.04, -0.005, 0.03, 0.065), (0.028, 0.045, 0.056, 0.05, 0.036)):
        loc, _ = hit((0, y, 2.5), (0, 0, -1))
        box(loc, (0.007, 0.03, h), "magenta", "Head", rot=Matrix.Rotation(math.radians(-25), 4, "X"),
            pre=Matrix.Translation((0, 0, h / 2 - 0.01)), bevel=0.0015)


def build_torso():
    spine = ["Spine", "Chest", "UpperChest"]
    # neck
    loft((0, 0.005, 1.43), (0, 0.005, 1.59), [(0, .04, .04), (.1, .043, .043), (.9, .04, .04), (1, .03, .03)],
         "chrome", ["Neck", "Head"])
    for z in (1.475, 1.505, 1.535):
        torus((0, 0.005, z), (0, 0, 1), 0.044, 0.005, "gunmetal", ["Neck", "Head"], seg=20, sseg=6)
    torus((0, 0.005, 1.465), (0, 0, 1), 0.075, 0.016, "armor", "UpperChest", Ry=0.066)
    torus((0, 0.005, 1.486), (0, 0, 1), 0.060, 0.004, "cyan", "UpperChest", Ry=0.052, sseg=6)

    # chest
    loft((0, 0.005, 1.14), (0, 0.005, 1.50),
         [(0, .09, .065), (.08, .12, .085), (.4, .152, .102), (.72, .163, .104), (.9, .14, .088), (1, .07, .05)],
         "suit", spine, seg=28)
    shell((0, 0.0, 1.36), (0.155, 0.118, 0.135), lambda n, c: n.y < -0.25 and c.z > 1.25, "armor", ["Chest", "UpperChest"])
    shell((0, 0.01, 1.36), (0.150, 0.118, 0.140), lambda n, c: n.y > 0.3 and c.z > 1.22, "armor", ["Chest", "UpperChest"])
    # chest core
    c, n = hit((0, -0.8, 1.33), (0, 1, 0), 0.003)
    torus(c, n, 0.024, 0.005, "cyan", ["Chest", "UpperChest"], sseg=6)
    sphere(c, 0.015, "magenta", ["Chest", "UpperChest"], scale=(1, 0.35, 1))
    for s in (1, -1):
        tube(surface_line([(s * 0.105, 1.45), (s * 0.035, 1.365)], "-y"), 0.0035, "cyan", ["Chest", "UpperChest"])
        tube(surface_line([(s * 0.125, 1.30), (s * 0.06, 1.275)], "-y"), 0.003, "magenta", ["Chest", "UpperChest"])
    # back: spine jack + exhaust ports
    c, n = hit((0, 0.8, 1.42), (0, -1, 0))
    box(c, (0.032, 0.03, 0.06), "gunmetal", "UpperChest", bevel=0.003)
    box(c + Vector((0, 0.016, 0)), (0.008, 0.004, 0.045), "cyan", "UpperChest")
    for s in (1, -1):
        c, n = hit((s * 0.065, 0.8, 1.35), (0, -1, 0))
        cylinder(c, (0, 1, 0), 0.02, 0.035, "gunmetal", ["Chest", "UpperChest"])
        torus(c + n * 0.018, (0, 1, 0), 0.016, 0.003, "magenta", ["Chest", "UpperChest"], seg=20, sseg=6)

    # abdomen
    ab = ["Hips", "Spine", "Chest"]
    loft((0, 0.01, 0.96), (0, 0.01, 1.22), [(0, .09, .065), (.5, .098, .072), (1, .09, .065)], "gunmetal", ab, seg=24)
    for z in (1.05, 1.09, 1.13):
        torus((0, 0.01, z), (0, 0, 1), 0.101, 0.007, "chrome", ab, Ry=0.075, sseg=6)

    # pelvis + belt
    loft((0, 0.008, 0.83), (0, 0.008, 1.03),
         [(0, .06, .045), (.15, .12, .08), (.5, .148, .098), (.85, .138, .092), (1, .1, .072)], "suit", "Hips", seg=28)
    torus((0, 0.008, 0.995), (0, 0, 1), 0.143, 0.013, "yellow", "Hips", Ry=0.096, seg=32)
    c, n = hit((0, -0.8, 0.995), (0, 1, 0), 0.004)
    box(c, (0.05, 0.012, 0.03), "gunmetal", "Hips", bevel=0.002)
    box(c + Vector((0, -0.007, 0)), (0.032, 0.004, 0.006), "cyan", "Hips")
    for s, side in ((1, "Left"), (-1, "Right")):
        box((s * 0.152, 0.008, 0.915), (0.016, 0.11, 0.11), "armor", ["Hips", side + "UpperLeg"],
            rot=Matrix.Rotation(math.radians(-s * 10), 4, "Y"), bevel=0.004)
        box((s * 0.161, -0.0, 0.915), (0.004, 0.006, 0.07), "magenta", ["Hips", side + "UpperLeg"],
            rot=Matrix.Rotation(math.radians(-s * 10), 4, "Y"))


def build_leg(s, side):
    UL, LL, FT, TO = side + "UpperLeg", side + "LowerLeg", side + "Foot", side + "Toes"
    sphere((s * 0.095, 0, 0.895), 0.062, "chrome", UL)
    loft((s * 0.095, 0, 0.93), (s * 0.10, 0, 0.50),
         [(0, .06, .06), (.1, .075, .078), (.4, .074, .076), (.85, .055, .058), (1, .045, .045)], "suit", UL, seg=20)
    shell((s * 0.10, 0, 0.72), (0.08, 0.083, 0.16), lambda n, c: n.y < -0.3, "armor", UL)
    tube(surface_line([(0, 0.86), (0, 0.62)], "x+" if s > 0 else "x-"), 0.0035, "cyan", UL)

    sphere((s * 0.10, 0, 0.51), 0.052, "chrome", LL)
    shell((s * 0.10, -0.035, 0.515), (0.05, 0.03, 0.055), lambda n, c: n.y < -0.1, "armor", LL, thick=0.005)
    loft((s * 0.10, 0, 0.50), (s * 0.10, 0.01, 0.09),
         [(0, .05, .05), (.2, .058, .062), (.5, .052, .056), (.9, .038, .04), (1, .035, .035)], "suit", LL, seg=20)
    shell((s * 0.10, 0.0, 0.29), (0.066, 0.07, 0.19), lambda n, c: n.y < -0.2, "armor", LL)
    tube(surface_line([(s * 0.10, 0.43), (s * 0.10, 0.16)], "-y"), 0.0035, "cyan", LL)
    torus((s * 0.10, 0.01, 0.112), (0, 0, 1), 0.039, 0.007, "cyan", LL, sseg=6)

    sphere((s * 0.10, 0.01, 0.085), 0.04, "chrome", FT)
    loft((s * 0.10, 0.065, 0.05), (s * 0.10, -0.105, 0.048),
         [(0, .02, .02), (.08, .044, .046), (.5, .048, .045), (1, .043, .035)], "gunmetal", FT, seg=16)
    loft((s * 0.10, -0.095, 0.042), (s * 0.10, -0.175, 0.038),
         [(0, .044, .036), (.6, .043, .032), (1, .015, .012)], "armor", TO, seg=16)
    box((s * 0.10, -0.04, 0.007), (0.078, 0.215, 0.014), "rubber", [FT, TO], bevel=0.005)
    box((s * 0.10, 0.06, 0.06), (0.07, 0.02, 0.04), "yellow", FT, bevel=0.004)


def build_arm(s, side):
    UA, LA, HD = side + "UpperArm", side + "LowerArm", side + "Hand"
    X = lambda x: s * x  # noqa: E731
    sphere((X(0.19), 0, ARM_Z), 0.052, "chrome", UA)
    shell((X(0.205), 0, 1.425), (0.085, 0.078, 0.072), lambda n, c: n.z > 0.05, "yellow", UA, thick=0.007)
    tube(surface_line([(X(0.215), -0.06), (X(0.215), -0.02), (X(0.215), 0.02), (X(0.215), 0.06)], "z"),
         0.0035, "magenta", UA)
    loft((X(0.19), 0, ARM_Z), (X(0.44), 0, ARM_Z),
         [(0, .045, .045), (.15, .05, .052), (.6, .047, .048), (1, .038, .038)], "suit", UA, seg=16)
    torus((X(0.33), 0, ARM_Z), (1, 0, 0), 0.049, 0.006, "magenta", UA, sseg=6)

    sphere((X(0.44), 0, ARM_Z), 0.04, "chrome", LA)
    loft((X(0.44), 0, ARM_Z), (X(0.685), 0, ARM_Z),
         [(0, .038, .038), (.25, .045, .046), (.8, .036, .036), (1, .03, .03)], "suit", LA, seg=16)
    shell((X(0.56), 0, ARM_Z), (0.10, 0.054, 0.054), lambda n, c: n.z > 0.05, "armor", LA)
    tube(surface_line([(X(0.49), 0), (X(0.63), 0)], "z"), 0.0035, "cyan", LA)
    torus((X(0.675), 0, ARM_Z), (1, 0, 0), 0.033, 0.006, "cyan", LA, sseg=6)

    loft((X(0.675), 0, ARM_Z), (X(0.785), 0, ARM_Z),
         [(0, .03, .02), (.15, .045, .02), (.85, .047, .016), (1, .03, .012)], "gunmetal", HD, seg=16)
    box((X(0.728), 0, ARM_Z + 0.017), (0.06, 0.068, 0.008), "armor", HD, bevel=0.003)
    box((X(0.728), 0, ARM_Z + 0.022), (0.04, 0.006, 0.003), "cyan", HD)
    for f, (y, lens, r) in FINGERS.items():
        for seg in SEGS:
            h, t = BONE_SEG[side + f + seg]
            d = (t - h).normalized()
            capsule(h - d * 0.004, t + d * 0.002, r, "chrome", side + f + seg)
            r *= 0.94
    r = 0.011
    for seg in SEGS:
        h, t = BONE_SEG[side + "Thumb" + seg]
        d = (t - h).normalized()
        capsule(h - d * 0.005, t + d * 0.002, r, "chrome", side + "Thumb" + seg)
        r *= 0.9


build_head()
build_torso()
for s, side in ((1, "Left"), (-1, "Right")):
    build_leg(s, side)
    build_arm(s, side)

# drop any geometry below the floor to exactly 0 is unnecessary; just report bounds
BM.verts.index_update()
TAG_IDX = {k: sorted({v.index for v in vs}) for k, vs in TAGS.items()}

# --------------------------------------------------------------------------
# Scene objects
# --------------------------------------------------------------------------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
os.makedirs(os.path.join(OUT, "textures"), exist_ok=True)
os.makedirs(os.path.join(OUT, "previews"), exist_ok=True)

me = bpy.data.meshes.new("Body")
body = bpy.data.objects.new("Body", me)
scene.collection.objects.link(body)
for name, *_ in BONES:
    body.vertex_groups.new(name=name)
BM.to_mesh(me)
BM.free()
me.update()

# Armature
arm_data = bpy.data.armatures.new("Armature")
arm = bpy.data.objects.new("Armature", arm_data)
scene.collection.objects.link(arm)
bpy.context.view_layer.objects.active = arm
arm.select_set(True)
bpy.ops.object.mode_set(mode="EDIT")
for n, h, t, p in BONES:
    eb = arm_data.edit_bones.new(n)
    eb.head, eb.tail = h, t
    if p:
        eb.parent = arm_data.edit_bones[p]
        eb.use_connect = (arm_data.edit_bones[p].tail - h).length < 1e-6 and not n.endswith("Eye")
bpy.ops.object.mode_set(mode="OBJECT")
arm_data.display_type = "STICK"
body.parent = arm
mod = body.modifiers.new("Armature", "ARMATURE")
mod.object = arm

# Shape keys --------------------------------------------------------------
body.shape_key_add(name="Basis", from_mix=False)
base = [v.co.copy() for v in me.vertices]


def local(i, tag):
    c, xa, za, _ = TAGINFO[tag]
    d = base[i] - c
    return d.dot(xa), d.dot(za), xa, za


def add_key(name, edits):
    """edits: {tag: f(u, w, s) -> (u', w')} in the part's local horizontal/vertical frame."""
    kb = body.shape_key_add(name=name, from_mix=False)
    for tag, f in edits.items():
        s = TAGINFO[tag][3]
        for i in TAG_IDX[tag]:
            u, w, xa, za = local(i, tag)
            nu, nw = f(u, w, s)
            kb.data[i].co = base[i] + xa * (nu - u) + za * (nw - w)


def mscale(sx, sz):
    return {"mouth": lambda u, w, s: (u * sx, w * sz)}


VISEMES = [("sil", .92, 1.0), ("pp", 1.0, .45), ("ff", .9, .9), ("th", .95, 1.6), ("dd", 1.0, 2.1),
           ("kk", 1.05, 2.6), ("ch", .8, 2.3), ("ss", 1.18, 1.3), ("nn", 1.0, 1.7), ("rr", .8, 2.1),
           ("aa", 1.1, 4.6), ("e", 1.28, 3.0), ("ih", 1.22, 2.0), ("oh", .62, 4.2), ("ou", .42, 3.1)]
for v, sx, sz in VISEMES:
    add_key("vrc.v_" + v, mscale(sx, sz))

blink = lambda u, w, s: (u, w * 0.08 - 0.001)  # noqa: E731
add_key("Blink", {"eyeL": blink, "eyeR": blink})
add_key("Blink_L", {"eyeL": blink})
add_key("Blink_R", {"eyeR": blink})
inner = lambda u, s: max(0.0, -s * u / 0.02)  # noqa: E731  1 at the inner end, 0 at the outer
outer = lambda u, s: max(0.0, s * u / 0.02)  # noqa: E731
happy_eye = lambda u, w, s: (u, w * 0.35 + 0.002 - (u / 0.02) ** 2 * 0.006)  # noqa: E731
add_key("Happy", {"eyeL": happy_eye, "eyeR": happy_eye,
                  "mouth": lambda u, w, s: (u * 1.15, w + (u / 0.017) ** 2 * 0.004)})
angry_eye = lambda u, w, s: (u, w * 0.7 - inner(u, s) * 0.005)  # noqa: E731
add_key("Angry", {"eyeL": angry_eye, "eyeR": angry_eye, "mouth": lambda u, w, s: (u * 0.8, w * 0.8)})
sad_eye = lambda u, w, s: (u, w * 0.8 + inner(u, s) * 0.004 - outer(u, s) * 0.002)  # noqa: E731
add_key("Sad", {"eyeL": sad_eye, "eyeR": sad_eye, "mouth": lambda u, w, s: (u, w - (u / 0.017) ** 2 * 0.004)})
wide = lambda u, w, s: (u * 1.15, w * 1.8)  # noqa: E731
add_key("Surprised", {"eyeL": wide, "eyeR": wide, "mouth": lambda u, w, s: (u * 0.5, w * 3.0)})

# Textures + material ------------------------------------------------------


def make_img(name, fn, noncolor=False):
    img = bpy.data.images.new(name, TEX, TEX, alpha=True)
    px = [0.0] * (TEX * TEX * 4)
    for y in range(TEX):
        for x in range(TEX):
            i = (y // CELL) * GRID + (x // CELL)
            rgba = fn(PALETTE[ORDER[i]]) if i < len(ORDER) else (0, 0, 0, 1)
            px[(y * TEX + x) * 4:(y * TEX + x) * 4 + 4] = rgba
    img.pixels = px
    if noncolor:
        img.colorspace_settings.name = "Non-Color"
    img.alpha_mode = "CHANNEL_PACKED"
    img.filepath_raw = os.path.join(OUT, "textures", name + ".png")
    img.file_format = "PNG"
    img.save()
    return img


albedo = make_img(NAME + "_Albedo", lambda p: (*p[0], 1.0))
emis = make_img(NAME + "_Emission", lambda p: (*p[1], 1.0))
metal = make_img(NAME + "_MetallicSmoothness", lambda p: (p[2], p[2], p[2], p[3]), noncolor=True)

mat = bpy.data.materials.new(NAME)
try:
    mat.use_nodes = True
except Exception:
    pass
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]


def tex(img, loc):
    n = nt.nodes.new("ShaderNodeTexImage")
    n.image, n.interpolation, n.location = img, "Closest", loc
    return n


ta, te, tm = tex(albedo, (-600, 300)), tex(emis, (-600, -300)), tex(metal, (-600, 0))
inv = nt.nodes.new("ShaderNodeMath")
inv.operation, inv.inputs[0].default_value, inv.location = "SUBTRACT", 1.0, (-300, -100)
nt.links.new(ta.outputs["Color"], bsdf.inputs["Base Color"])
nt.links.new(tm.outputs["Color"], bsdf.inputs["Metallic"])
nt.links.new(tm.outputs["Alpha"], inv.inputs[1])
nt.links.new(inv.outputs[0], bsdf.inputs["Roughness"])
nt.links.new(te.outputs["Color"], bsdf.inputs["Emission Color"])
bsdf.inputs["Emission Strength"].default_value = 8.0
me.materials.append(mat)

# Stats ------------------------------------------------------------------
tris = sum(len(p.vertices) - 2 for p in me.polygons)
unweighted = sum(1 for v in me.vertices if not v.groups)
zs = [v.co.z for v in me.vertices]
print(f"[{NAME}] verts={len(me.vertices)} tris={tris} bones={len(BONES)} shape_keys={len(me.shape_keys.key_blocks)}"
      f" unweighted={unweighted} height={max(zs):.3f}m bottom={min(zs):.4f}")
assert unweighted == 0

# Export -----------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
arm.select_set(True)
body.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.export_scene.fbx(
    filepath=os.path.join(OUT, NAME + ".fbx"), use_selection=True, object_types={"ARMATURE", "MESH"},
    apply_unit_scale=True, apply_scale_options="FBX_SCALE_ALL", axis_forward="-Z", axis_up="Y",
    use_mesh_modifiers=False, mesh_smooth_type="FACE", add_leaf_bones=False, primary_bone_axis="Y",
    secondary_bone_axis="X", use_armature_deform_only=True, armature_nodetype="NULL", bake_anim=False,
    path_mode="COPY", embed_textures=True)

# Preview renders ----------------------------------------------------------


def look(obj, target):
    obj.rotation_euler = (V(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def setup_stage():
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 96
    try:
        scene.cycles.use_denoising = True
    except Exception:
        pass
    scene.render.resolution_x, scene.render.resolution_y = 900, 1200
    try:
        scene.view_settings.look = "AgX - Medium High Contrast"
    except Exception:
        pass
    world = bpy.data.worlds.new("World")
    scene.world = world
    try:
        world.use_nodes = True
    except Exception:
        pass
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.006, 0.005, 0.016, 1)

    fm = bpy.data.meshes.new("Floor")
    fm.from_pydata([(-6, -6, 0), (6, -6, 0), (6, 6, 0), (-6, 6, 0)], [], [(0, 1, 2, 3)])
    floor = bpy.data.objects.new("Floor", fm)
    scene.collection.objects.link(floor)
    fmat = bpy.data.materials.new("FloorMat")
    try:
        fmat.use_nodes = True
    except Exception:
        pass
    fb = fmat.node_tree.nodes["Principled BSDF"]
    fb.inputs["Base Color"].default_value = (0.012, 0.012, 0.02, 1)
    fb.inputs["Roughness"].default_value = 0.28
    fm.materials.append(fmat)

    def light(name, kind, loc, energy, color, size=1.0):
        ld = bpy.data.lights.new(name, kind)
        ld.energy, ld.color = energy, color
        if kind == "AREA":
            ld.size = size
        lo = bpy.data.objects.new(name, ld)
        lo.location = loc
        scene.collection.objects.link(lo)
        look(lo, (0, 0, 1.1))

    light("Key", "AREA", (-1.8, -2.4, 2.6), 450, (1.0, 0.95, 0.92), 1.5)
    light("RimMagenta", "AREA", (2.2, 1.8, 2.0), 600, (1.0, 0.2, 0.7), 1.2)
    light("RimCyan", "AREA", (-2.2, 1.6, 1.6), 450, (0.2, 0.85, 1.0), 1.2)
    light("Fill", "AREA", (2.0, -2.5, 0.8), 90, (0.6, 0.7, 1.0), 2.0)

    cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    return cam


def pose(rotations):
    """rotations: {bone: (axis, degrees)} rotation in armature (rest) space about the bone head."""
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = (1, 0, 0, 0)
    for name, (axis, deg) in rotations.items():
        pb = arm.pose.bones[name]
        rest = pb.bone.matrix_local.to_quaternion()
        qw = Matrix.Rotation(math.radians(deg), 4, axis).to_quaternion()
        pb.rotation_quaternion = rest.inverted() @ qw @ rest
    bpy.context.view_layer.update()


def keys(**vals):
    for kb in me.shape_keys.key_blocks[1:]:
        kb.value = vals.get(kb.name.replace(".", "_"), 0.0)


def shot(cam, name, loc, target, lens=50):
    cam.location = loc
    cam.data.lens = lens
    look(cam, target)
    scene.render.filepath = os.path.join(OUT, "previews", name + ".png")
    bpy.ops.render.render(write_still=True)
    print("rendered", name)


if RENDER:
    cam = setup_stage()
    pose({})
    keys()
    shot(cam, "01_tpose_front", (0, -4.6, 1.0), (0, 0, 0.95), 50)
    pose({"LeftUpperArm": ("Y", 70), "RightUpperArm": ("Y", -70),
          "LeftLowerArm": ("Z", -15), "RightLowerArm": ("Z", 15),
          "LeftUpperLeg": ("Y", -4), "RightUpperLeg": ("Y", 4),
          "Head": ("X", -6)})
    keys(Happy=1.0)
    shot(cam, "02_idle_three_quarter", (1.9, -3.2, 1.25), (0, 0, 0.92), 50)
    keys(vrc_v_aa=1.0)
    shot(cam, "03_face_viseme_aa", (0.32, -0.85, 1.72), (0, -0.05, 1.67), 60)
    keys(Angry=1.0)
    shot(cam, "04_face_angry", (-0.32, -0.85, 1.72), (0, -0.05, 1.67), 60)
    shot(cam, "05_back", (-1.6, 3.4, 1.4), (0, 0, 0.95), 50)
    pose({})
    keys()

bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, NAME + ".blend"))
print("done")
