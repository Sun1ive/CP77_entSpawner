// @author Akiway
// @version 1.0.0
//
// @description
// Read the rig and the animation names out of every door `.anims` set, so the Transform Animations
// panel can offer only swaps that share a rig.
//
// The rig is the compatibility key: `entAnimatedComponent.animations.gameplay[].animSet` can be
// repointed through instance data, but an `.anims` built for a different skeleton drives bones the
// door does not have. Folder is not a good enough proxy -- `door_double.anims` and
// `door_single.anims` sit in sibling folders and do not share a rig.
//
// Writes door_anim_rigs.json into WolvenKit's raw output folder. Copy it to
// data/static/door_anim_rigs.json in the mod for doorAnimSets.lua to pick it up. Re-run after a
// game update; the panel offers no swap for a set that is not in the store.
//
// Output shape:
// { "version": 1, "sets": { "<anims path>": { "rig": "<rig path>", "animations": [ {name,duration} ] } } }

const SEARCH = "animations\\items\\interactive\\doors\\";
const OUTPUT = "door_anim_rigs.json";

function readJson(path) {
    var text = null;
    try {
        text = wkit.GetFileFromArchive(path, OpenAs.Json);
    } catch (e) {
        try {
            text = wkit.GetFile(path, OpenAs.Json);
        } catch (e2) {
            console.warn("read failed: " + path);
            return null;
        }
    }
    if (!text) return null;
    try {
        return JSON.parse(text);
    } catch (e) {
        console.warn("parse failed: " + path);
        return null;
    }
}

// RED JSON wraps resource refs under DepotPath and most leaves as { "$value": ... }.
function refValue(node) {
    if (!node || !node.DepotPath) return "";
    var depot = node.DepotPath;
    return (typeof depot === "string") ? depot : (depot["$value"] || "");
}

function nameValue(node) {
    if (!node) return "";
    return (typeof node === "string") ? node : (node["$value"] || "");
}

var sets = {};
var count = 0;

for (const file of wkit.GetArchiveFiles()) {
    var name = "";
    try { name = String(file.FileName || ""); } catch (e) { continue; }
    if (!name || name.indexOf(SEARCH) < 0) continue;
    if (!name.toLowerCase().endsWith(".anims")) continue;

    var parsed = readJson(name);
    if (!parsed || !parsed.Data || !parsed.Data.RootChunk) continue;

    var root = parsed.Data.RootChunk;
    var entry = { rig: refValue(root.rig), animations: [] };

    var anims = root.animations || [];
    for (var a = 0; a < anims.length; a++) {
        var holder = anims[a] && anims[a].Data ? anims[a].Data : anims[a];
        var animation = holder && holder.animation ? holder.animation : null;
        var animData = animation && animation.Data ? animation.Data : animation;
        if (!animData) continue;
        entry.animations.push({ name: nameValue(animData.name), duration: animData.duration || 0 });
    }

    sets[name] = entry;
    count++;
    console.log(name + "  rig=" + entry.rig + "  anims=" + entry.animations.length);
}

console.log("collected " + count + " door anim sets");
wkit.SaveToRaw(OUTPUT, JSON.stringify({ version: 1, sets: sets }, null, 2));
console.log("written " + OUTPUT);
