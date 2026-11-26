# tools/

## Regenerate the Quaternius character GLBs

`prep_skinned_glb.py` builds `static/models/{mannequin,superhero_male,superhero_female}.glb`
from the original Quaternius packages (CC0 1.0). Input can be the original `.zip` files or
extracted folders. Run from the repository root; needs Python 3 with `numpy` and `Pillow`.

```sh
Z=~/Desktop/assets-src/UniversalBaseCharacters-Standard.zip
A=~/Desktop/assets-src/UniversalAnimationLibrary-Standard.zip/UAL1_Standard.glb
B=$Z/Superhero_Male_FullBody.gltf
F=$Z/Superhero_Female_FullBody.gltf
R="Rigged to Head Bone/glTF (Godot -Unreal)"

python3 tools/prep_skinned_glb.py --ual "$A" --out static/models/mannequin.glb
python3 tools/prep_skinned_glb.py --ual "$A" --character "$B" \
  --hair "$Z/$R/Hair_SimpleParted.gltf" --hair "$Z/$R/Hair_Beard.gltf" \
  --out static/models/superhero_male.glb
python3 tools/prep_skinned_glb.py --ual "$A" --character "$F" \
  --hair "$Z/$R/Hair_Long.gltf" \
  --out static/models/superhero_female.glb
```

Path forms:
- `<package>.zip/<caminho final>`: extracts the zip to a temp directory. The part after
  `.zip/` must match exactly one file by path suffix (e.g. `Rigged to Head Bone/glTF (Godot -Unreal)/Hair_Long.gltf`).
  Ambiguous or missing names raise an error.
- An extracted file path works as-is, e.g.
  `--ual "/path/Universal Animation Library[Standard]/Unreal-Godot/UAL1_Standard.glb"`.

`--hair` (repeatable) adds the primitives of a hairstyle glTF to the character mesh. Its joint
names must match the character's skin order (asserted). Hairstyle textures are not used:
the atlas takes the character's own `T_Hair_1`/`T_Hair_2`, which are byte-identical to the
hairstyle files' base colour maps.

The output is deterministic: running the commands above reproduces the committed GLBs
byte for byte (verify with `cmp`).

Inputs: `UAL1_Standard.glb` (not the `_RM` root-motion variant), the
`Superhero_{Male,Female}_FullBody.gltf` files, and the hairstyle `.gltf` files
(`Hairstyles/Rigged to Head Bone/glTF (Godot -Unreal)/`). Provenance and limits: `static/models/README-characters.txt`.
