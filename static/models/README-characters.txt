Quaternius characters (CC0 1.0 Universal)

mannequin.glb
  Source: Universal Animation Library [Standard] by Quaternius
          https://quaternius.itch.io/universal-animation-library
          (Unreal-Godot/UAL1_Standard.glb, mesh "Mannequin", no root motion)
  License: CC0 1.0 (Quaternius)

superhero_male.glb
  Source: Universal Base Characters [Standard] by Quaternius
          https://quaternius.itch.io/universal-base-characters
          Base: Base Characters/Godot - UE/Superhero_Male_FullBody.gltf (body, eyes, eyebrows)
          Hair: Hairstyles/Rigged to Head Bone/glTF (Godot -Unreal)/Hair_SimpleParted.gltf
                and Hair_Beard.gltf (rigged to the same 65-bone skin)
  Animations: Universal Animation Library [Standard] (as above), retargeted by bone name
  License: CC0 1.0 (Quaternius)

superhero_female.glb
  Source: Universal Base Characters [Standard] by Quaternius
          https://quaternius.itch.io/universal-base-characters
          Base: Base Characters/Godot - UE/Superhero_Female_FullBody.gltf (body, eyes, eyebrows)
          Hair: Hairstyles/Rigged to Head Bone/glTF (Godot -Unreal)/Hair_Long.gltf
  Animations: Universal Animation Library [Standard] (as above), retargeted by bone name
  License: CC0 1.0 (Quaternius)

Modifications (made by tools/prep_skinned_glb.py; see tools/README.md to regenerate):
  - Single skin (65 joints, names and order identical in UAL, characters and hairstyles),
    single material.
  - Hairstyle primitives are merged into the character mesh. Their vertices are weighted only
    to the Head bone, whose inverse bind matrix matches the character's exactly.
  - Texture: one 2048x2048 PNG atlas (body 1024, hair 1024, eyes 2x2 tiles of 256), because
    the engine supports one texture per model. The hair region uses the character's own
    T_Hair_1 (male) or T_Hair_2 (female); these are byte-identical to the hairstyle files'
    base colour maps. Only baseColor maps are kept; normal, roughness and metallicRoughness
    maps are dropped.
  - Eye UVs above 1 (up to ~1.2) are remapped onto the tiled eye region.
  - Animations: 18 clips selected from the UAL (listed in the script's CLIPS), written as
    deltas over the UAL rest pose and applied over the character rest pose. Channels constant
    and equal to the rest pose are removed.
  - Not included: the other hairstyles (Buzzed, Buns, BuzzedFemale, and the non-chosen ones of
    male/female), Eyebrows_Regular / Eyebrows_Female, and the FBX/Unity variants.
  - Hair colour: the hair region (hairstyles, beard, FullBody eyebrows) is multiplied in the atlas by
    HAIR_TINT in tools/prep_skinned_glb.py: male dark brown (0.30, 0.19, 0.11), female golden blond
    (0.78, 0.60, 0.28), sRGB. The skinned shader ignores baseColorFactor, so the colour is baked.
  - mannequin.glb: TEXCOORD dropped, flat grey (MANNEQUIN_GREY = 0.35) baked into a 1x1 texture.

Known limits: the FullBody eyebrows (MI_Hair_1 / MI_Hair_2) are kept as the only brow geometry.
Hairstyles are rigid to the Head bone, so they follow head motion only; they do not
deform with the neck. Character proportions differ from the UAL rig (hand/foot distance
errors of roughly 2-14 cm), so animated hands and feet can drift from the ground or the
body by that amount.
