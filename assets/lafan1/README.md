# LAFAN1 clips

Motion from Ubisoft La Forge's **LAFAN1** dataset, in two forms.

## The tracking set: LAFAN1 on Geno (what we learn to track)

Four clips on the **Geno** skeleton - the one the dance examples already use, so they go through
the same retargeting path (`Geno_stance.bvh` here as the rest pose, the LAFAN match table):

| file | what it is | frames | seconds |
|---|---|---|---|
| `walk1_subject2.bvh` | walking: forwards, turning, stopping | 1,200 | 20.0 |
| `run1_subject2.bvh` | running, with turns | 1,200 | 20.0 |
| `dance2_subject2.bvh` | dancing | 1,200 | 20.0 |
| `fallAndGetUp2_subject2.bvh` | standing, falling, lying on the floor, getting up | 1,080 | 18.0 |
| `Geno_stance.bvh` | the rest pose for all four (one frame) | 1 | - |

They come from Holden's **LaFAN resolved** (LAFAN1 retargeted onto Geno), cut out of the full
takes and stripped of their forty finger joints - no robot here has fingers, and they were two
thirds of the file. Each clip's window skips the binding pose at the start of a take; the get-up's
covers a whole standing → fall → ground → rise cycle. Regenerate any of them with:

    zig build bvh-trim -- <take>.bvh assets/lafan1/<name>.bvh <first frame> <frames> Thumb Index Middle Ring Pinky

Retargeted onto `humanoid_flex2` and filtered at 5 Hz, all four audit clean (the "reference set"
test): IK residual 4.9-5.9 cm mean, no hinge out of range, no quaternion sign flips, no
single-frame jump past 0.15 rad. They do put the body through the floor where grounding can't
help - 3 cm for walking, running and dancing, 10 cm for the get-up, which spends its time lying
down.

## The motion-matching set: LAFAN1 on its own skeleton

Three takes by subject 5 on LAFAN's own 22-bone skeleton, converted from the motion-matching
database in Holden's Motion-Matching demo by `tools/lafan_db.zig` (which verifies every file it
writes against the database, joint by joint, to 0.001 cm): `walk1_subject5.bvh`,
`run1_subject5.bvh` (60 s each) and `pushAndStumble1_subject5.bvh` (4.7 s). They are resampled to
60 fps and play 10% faster, by that database's design. Kept for the motion-matching work later,
and as a second route to the same takes.

    zig build lafan-db -- <path to database.bin> assets/lafan1 60

## Licence

The motion is LAFAN1's, licensed by Ubisoft La Forge under **CC BY-NC-ND 4.0** (attribution,
non-commercial, no derivatives); these files are format conversions of it for research use in this
engine. Holden's processing and retargeting code is MIT.
