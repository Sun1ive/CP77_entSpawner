// @author Akiway
// @version 1.0.0
//
// @description
// Build data/static/workspot_sync.json: which .workspot completes a synced one, and where the
// second AI Spot goes relative to the first.
//
// Two sources, in this order of trust:
//   authored  workSyncAnimClip.syncOffset inside the .workspot itself. It is the transform of the
//             partner spot in this spot's local frame, and shipped sectors place synced pairs at
//             exactly that offset.
//   measured  How the pair is actually placed in shipped sectors. Added only when the dominant
//             placement matches no authored arrangement - either because both halves leave
//             syncOffset unset, or because the level designers ignored what it says.
//   scene     Where a shipped .scene stages the couple. Added only while nothing above says where
//             the partner goes, since a scene stages one moment of a pair authored for several.
//
// Pairing comes from workSyncAnimClip.slotName: two workspots that carry the same slot with a
// DIFFERENT animName are the two halves of one scene. Same slot with the same animName is the same
// half shipped twice - the base-game and Phantom Liberty copies of a scene - not a partner.
//
// Quest workspots carry no sync clip at all, so nothing inside them pairs them up. They are paired
// off shipped scenes instead: a scene binds every workspot instance to an entity, so two instances
// a step apart that belong to two DIFFERENT entities are one couple, and their instance transforms
// give the offset. Two instances of one entity are alternative poses of one role, not a couple.
//
// Which half leads is NOT in the workspot: nothing in the resource distinguishes the master from
// the child, and neither the npc1/npc2 naming nor the shape of the sync clips predicts it. It is an
// authoring convention, so it is counted off shipped placements instead - a given pair keeps the
// same direction 92% of the time, which is what the "master" field records.
//
// Output shape:
// {
//   "version": 1,
//   "workspots": {
//     "<workspot path, lowercase>": {
//       "path": "<workspot path>",
//       "partners": [{
//         "path": "<partner workspot path>",
//         "vanilla": <shipped pairs observed>,
//         "master": [<times this spot led>, <times the partner led>],
//         "arrangements": [{
//           "slots": ["<slot name>"],   // empty for a measured arrangement
//           "o": [x, y, z, yaw],        // partner in this spot's local frame, yaw in degrees
//           "src": "authored" | "authoredInverse" | "measured" | "scene",
//           "n": <shipped pairs observed at this arrangement>
//         }]
//       }]
//     }
//   }
// }
//
// An arrangement whose offset is all zeroes and whose n is 0 means nothing shipped backs it: the
// two halves are known to belong together, but where the second one goes is not recorded anywhere,
// so it has to be placed by hand.

const settings = {
    workspotListFile: "aiSpot\\paths_workspot.txt",
    outputPathInResources: "workspot_sync.json",
    // Workspots that only ever sync the player with a device (takedowns, disposal, doors, vehicles).
    // They are never placed on a worldAISpotNode, so they would only clutter the picker.
    excludePathParts: [
        "gameplay\\workspots", "\\vehicles\\", "\\car\\",
        "gameplay\\devices", "gameplay\\finishers", "gameplay\\vehicles"
    ],
    posTolerance: 0.06,      // metres, when deciding two transforms are the same arrangement
    yawTolerance: 3.0,       // degrees, same
    maxPairDistance: 3.0,    // metres, how far apart two spots of one couple can sit
    sceneMaxPairDistance: 1.5,  // metres, same for a scene - its couples touch, a wider radius
                                // only picks up bystanders standing around them
    minMeasuredCount: 3,     // shipped couples needed before a measured arrangement is offered
    progressEvery: 250
};

const R2D = 180 / Math.PI;

function logInfo(message) { try { logger.Info("[workspot-sync] " + message); } catch (_) {} }
function logWarn(message) { try { logger.Warning("[workspot-sync] " + message); } catch (_) {} }

function normalizePath(value) {
    return String(value === null || value === undefined ? "" : value).trim().replace(/\//g, "\\");
}

function normYaw(a) {
    while (a > 180) a -= 360;
    while (a <= -180) a += 360;
    return a;
}

function yawOf(q) {
    return Math.atan2(2 * (q.r * q.k + q.i * q.j), 1 - 2 * (q.j * q.j + q.k * q.k)) * R2D;
}

function isIdentity(o) {
    return Math.abs(o[0]) < 1e-4 && Math.abs(o[1]) < 1e-4 && Math.abs(o[2]) < 1e-4 && Math.abs(normYaw(o[3])) < 1e-3;
}

function invert(o) {
    const c = Math.cos(o[3] / R2D), s = Math.sin(o[3] / R2D);
    return [-(o[0] * c + o[1] * s), -(-o[0] * s + o[1] * c), -o[2], normYaw(-o[3])];
}

function sameTransform(a, b) {
    return Math.hypot(a[0] - b[0], a[1] - b[1]) < settings.posTolerance
        && Math.abs(a[2] - b[2]) < 0.25
        && Math.abs(normYaw(a[3] - b[3])) < settings.yawTolerance;
}

function round4(v) { return Math.round(v * 10000) / 10000; }

// Instances only share a frame when they hang off the same scene marker.
function markerKey(marker) {
    const m = marker || {};
    const ref = m.entityRef || {};
    return [
        String(m.type || "?"),
        m.nodeRef ? String(m.nodeRef["$value"]) : "0",
        ref.reference ? String(ref.reference["$value"]) : "0",
        ref.dynamicEntityUniqueName ? String(ref.dynamicEntityUniqueName["$value"]) : "None",
        m.localMarkerId ? String(m.localMarkerId["$value"]) : "None",
        m.slotName ? String(m.slotName["$value"]) : "None"
    ].join("|");
}

function sharesUser(a, b) {
    for (const user of Object.keys(a.users)) if (b.users[user]) return true;
    return false;
}

// Compared byte by byte, the way the offline build of this file orders its keys.
function compareText(a, b) { return a < b ? -1 : (a > b ? 1 : 0); }

// Which set a workspot belongs to. A scene shipped in both the base game and Phantom Liberty has
// a copy of each half in each set, and every copy pairs with every other.
function pathFamily(path) {
    const name = path.split("\\").pop();
    for (const prefix of ["ue__", "ep1__", "dep__"]) if (name.indexOf(prefix) === 0) return prefix;
    return "";
}

// Last segment of a NodeRef, without the "#" that marks a name rather than a path step.
function refTail(ref) {
    const parts = String(ref).split("/");
    return parts[parts.length - 1].replace(/^#/, "");
}

function readJson(path) {
    let text = null;
    try { text = wkit.GetFile(path, OpenAs.Json); } catch (_) {}
    if (!text) return null;
    try { return JSON.parse(String(text)); } catch (err) { logWarn("Invalid JSON for " + path + ": " + err); return null; }
}

function loadWorkspotList() {
    let text = null;
    try { text = wkit.LoadFromResources(settings.workspotListFile); } catch (_) {}
    if (!text) throw new Error("Could not read resources/" + settings.workspotListFile);

    const out = [], seen = Object.create(null);
    for (const line of String(text).split(/\r?\n/)) {
        const p = normalizePath(line);
        if (!p || p.toLowerCase().indexOf(".workspot") < 0) continue;
        const lower = p.toLowerCase();
        if (seen[lower]) continue;

        let excluded = false;
        for (const part of settings.excludePathParts) {
            if (lower.indexOf(part) >= 0) { excluded = true; break; }
        }
        if (excluded) continue;

        seen[lower] = true;
        out.push(p);
    }
    out.sort();
    return out;
}

// ---------------------------------------------------------------- workspots
// Per workspot: the sync clips it carries, keyed by slot name.
function readSyncClips(workspotPath) {
    const json = readJson(workspotPath);
    if (!json) return null;

    const bySlot = Object.create(null);
    (function walk(node) {
        if (node === null || typeof node !== "object") return;
        if (Array.isArray(node)) { for (const child of node) walk(child); return; }

        if (node["$type"] === "workSyncAnimClip" && node.syncOffset) {
            const slot = node.slotName ? String(node.slotName["$value"]) : "None";
            if (slot !== "None" && slot !== "" && !bySlot[slot]) {
                const p = node.syncOffset.position;
                bySlot[slot] = {
                    anim: node.animName ? String(node.animName["$value"]) : "",
                    o: [p.X, p.Y, p.Z, yawOf(node.syncOffset.orientation)]
                };
            }
        }

        for (const key of Object.keys(node)) walk(node[key]);
    })(json.Data ? json.Data.RootChunk : json);

    return Object.keys(bySlot).length > 0 ? bySlot : null;
}

// ------------------------------------------------------------- measurements
// Relative transforms of synced AI Spot couples as the game ships them, plus which half of each
// pair carries masterNodeRef. Only mutual nearest neighbours count as a couple: in a crowded sector
// a spot sits close to plenty of unrelated spots, and those would otherwise look like real
// arrangements.
function readPlacements(isSyncWorkspot) {
    const observed = Object.create(null);
    const masterEdges = Object.create(null);   // "slave|master" -> n

    for (let s = 0; s < PLACEMENT_SECTORS.length; s++) {
        const json = readJson(PLACEMENT_SECTORS[s]);
        if (!json) continue;

        const root = json.Data.RootChunk;
        const byIndex = Object.create(null);
        for (const entry of root.nodeData.Data) {
            (byIndex[entry.NodeIndex] = byIndex[entry.NodeIndex] || []).push(entry);
        }

        const spots = [];
        for (let i = 0; i < root.nodes.length; i++) {
            const data = root.nodes[i].Data;
            if (!data || data["$type"] !== "worldAISpotNode") continue;
            const spot = data.spot && data.spot.Data;
            if (!spot || !spot.resource) continue;
            const res = normalizePath(spot.resource.DepotPath["$value"]);
            if (!isSyncWorkspot[res.toLowerCase()]) continue;

            for (const entry of byIndex[i] || []) {
                spots.push({
                    res: res,
                    ref: entry.QuestPrefabRefHash ? String(entry.QuestPrefabRefHash["$value"]) : "",
                    master: spot.masterNodeRef ? String(spot.masterNodeRef["$value"]) : "0",
                    x: entry.Position.X, y: entry.Position.Y, z: entry.Position.Z,
                    yaw: yawOf(entry.Orientation)
                });
            }
        }

        // masterNodeRef is a relative ref, so it resolves against the other spots of this sector.
        const byRef = Object.create(null);
        for (const spot of spots) byRef[refTail(spot.ref)] = spot;
        for (const spot of spots) {
            if (spot.master === "0" || spot.master === "") continue;
            const target = byRef[refTail(spot.master)];
            if (!target || target.res === spot.res) continue;
            const key = spot.res.toLowerCase() + "|" + target.res.toLowerCase();
            masterEdges[key] = (masterEdges[key] || 0) + 1;
        }

        const nearest = [];
        for (let i = 0; i < spots.length; i++) {
            let best = -1, bestDistance = settings.maxPairDistance;
            for (let j = 0; j < spots.length; j++) {
                if (i === j || spots[i].res === spots[j].res) continue;
                const d = Math.hypot(spots[i].x - spots[j].x, spots[i].y - spots[j].y, spots[i].z - spots[j].z);
                if (d < bestDistance) { best = j; bestDistance = d; }
            }
            nearest.push(best);
        }

        for (let i = 0; i < spots.length; i++) {
            const j = nearest[i];
            if (j < 0 || nearest[j] !== i) continue;
            const a = spots[i], b = spots[j];
            const c = Math.cos(a.yaw / R2D), sn = Math.sin(a.yaw / R2D);
            const dx = b.x - a.x, dy = b.y - a.y;
            const key = a.res.toLowerCase() + "|" + b.res.toLowerCase();
            (observed[key] = observed[key] || []).push(
                [dx * c + dy * sn, -dx * sn + dy * c, b.z - a.z, normYaw(b.yaw - a.yaw)]);
        }

        if ((s + 1) % settings.progressEvery === 0) {
            logInfo("Sectors " + (s + 1) + "/" + PLACEMENT_SECTORS.length);
        }
    }

    return { observed: observed, masterEdges: masterEdges };
}

// ------------------------------------------------------------------- scenes
// Where a shipped scene stages a couple, and which two workspots that couple is made of. Only
// synced workspots take part: an ambient one often sits at the exact same spot as a synced one
// - the chair a scene seats two characters on in turn - and would then steal the couple.
function readScenePairs(listed, isSyncWorkspot) {
    const observed = Object.create(null);      // "a|b" -> [transform]

    function isSyncSpot(path) {
        if (!listed[path]) return false;
        if (isSyncWorkspot[path]) return true;
        const parts = path.split("\\");
        return parts[parts.length - 1].indexOf("synced") >= 0;
    }

    for (let s = 0; s < SCENE_FILES.length; s++) {
        const json = readJson(SCENE_FILES[s]);
        if (!json) continue;
        const root = json.Data ? json.Data.RootChunk : json;

        const byData = Object.create(null);
        for (const entry of root.workspots || []) {
            const data = entry.Data;
            if (!data || data["$type"] !== "scnWorkspotData_ExternalWorkspotResource") continue;
            const resource = data.workspotResource ? data.workspotResource.DepotPath : null;
            if (!resource || resource["$storage"] !== "string") continue;
            byData[String(data.dataId.id)] = normalizePath(resource["$value"]).toLowerCase();
        }
        if (Object.keys(byData).length === 0) continue;

        // Workspot instance -> the entities that use it, walked out of the quest graph.
        const users = Object.create(null);
        (function walk(node) {
            if (node === null || typeof node !== "object") return;
            if (Array.isArray(node)) { for (const child of node) walk(child); return; }

            if (node["$type"] === "questUseWorkspotNodeDefinition") {
                const params = node.paramsV1 ? node.paramsV1.Data : null;
                if (params && params.workspotInstanceId) {
                    const ref = node.entityReference || {};
                    const names = [];
                    for (const name of ref.names || []) names.push(String(name["$value"]));
                    const key = names.join(",")
                        + "|" + (ref.reference ? String(ref.reference["$value"]) : "0")
                        + "|" + (ref.dynamicEntityUniqueName ? String(ref.dynamicEntityUniqueName["$value"]) : "None")
                        + "|" + (params.isPlayer ? "player" : "");
                    const id = String(params.workspotInstanceId.id);
                    (users[id] = users[id] || Object.create(null))[key] = true;
                }
            }

            for (const key of Object.keys(node)) walk(node[key]);
        })(root);

        const groups = Object.create(null);
        for (const instance of root.workspotInstances || []) {
            const res = byData[String(instance.dataId.id)];
            // An instance played at the actor's location says nothing about where a spot goes.
            if (!res || instance.playAtActorLocation || !isSyncSpot(res)) continue;
            const t = instance.localTransform;
            if (!t || !t.position || !t.orientation) continue;
            const own = users[String(instance.workspotInstanceId.id)];
            if (!own) continue;

            const group = groups[markerKey(instance.originMarker)] = groups[markerKey(instance.originMarker)] || [];
            const transform = [t.position.X, t.position.Y, t.position.Z, yawOf(t.orientation)];

            // One workspot is usually instanced several times over at the same spot of a scene.
            let merged = false;
            for (const entry of group) {
                if (entry.res === res && sameTransform(entry.t, transform)) {
                    for (const user of Object.keys(own)) entry.users[user] = true;
                    merged = true;
                    break;
                }
            }
            if (merged) continue;

            const copy = Object.create(null);
            for (const user of Object.keys(own)) copy[user] = true;
            group.push({ res: res, t: transform, users: copy });
        }

        for (const marker of Object.keys(groups)) {
            const group = groups[marker];
            const nearest = [];
            for (let i = 0; i < group.length; i++) {
                let best = -1, bestDistance = settings.sceneMaxPairDistance;
                for (let j = 0; j < group.length; j++) {
                    if (i === j || group[i].res === group[j].res || sharesUser(group[i], group[j])) continue;
                    const d = Math.hypot(group[i].t[0] - group[j].t[0], group[i].t[1] - group[j].t[1], group[i].t[2] - group[j].t[2]);
                    if (d < bestDistance) { best = j; bestDistance = d; }
                }
                nearest.push(best);
            }

            for (let i = 0; i < group.length; i++) {
                const j = nearest[i];
                if (j < 0 || nearest[j] !== i) continue;
                const a = group[i].t, b = group[j].t;
                const c = Math.cos(a[3] / R2D), sn = Math.sin(a[3] / R2D);
                const dx = b[0] - a[0], dy = b[1] - a[1];
                const key = group[i].res + "|" + group[j].res;
                (observed[key] = observed[key] || []).push(
                    [dx * c + dy * sn, -dx * sn + dy * c, b[2] - a[2], normYaw(b[3] - a[3])]);
            }
        }

        if ((s + 1) % settings.progressEvery === 0) {
            logInfo("Scenes " + (s + 1) + "/" + SCENE_FILES.length);
        }
    }

    // A workspot a scene puts next to several different ones is a bystander, not half of a couple.
    const partnerCount = Object.create(null);
    for (const key of Object.keys(observed)) {
        const parts = key.split("|");
        (partnerCount[parts[0]] = partnerCount[parts[0]] || Object.create(null))[parts[1]] = true;
    }

    const pairs = Object.create(null);
    for (const key of Object.keys(observed)) {
        const parts = key.split("|");
        if (Object.keys(partnerCount[parts[0]]).length !== 1) continue;
        if (!partnerCount[parts[1]] || Object.keys(partnerCount[parts[1]]).length !== 1) continue;

        const clusters = clusterObservations(observed[key]);
        pairs[key] = { o: clusters[0].centre.map(round4), n: clusters[0].n };
    }

    return pairs;
}

function clusterObservations(list) {
    const clusters = [];
    for (const o of list || []) {
        let merged = false;
        for (const cluster of clusters) {
            if (sameTransform(cluster.centre, o)) {
                cluster.n += 1;
                for (let i = 0; i < 4; i++) cluster.sum[i] += (i === 3 ? normYaw(o[i] - cluster.centre[i]) + cluster.centre[i] : o[i]);
                for (let i = 0; i < 4; i++) cluster.centre[i] = cluster.sum[i] / cluster.n;
                merged = true;
                break;
            }
        }
        if (!merged) clusters.push({ centre: o.slice(), sum: o.slice(), n: 1 });
    }
    clusters.sort(function (a, b) { return b.n - a.n; });
    return clusters;
}

function main() {
    logInfo("Starting synced workspot extraction");

    const workspots = loadWorkspotList();
    logInfo("Candidate workspots: " + workspots.length);

    const listed = Object.create(null);
    for (const path of workspots) listed[path.toLowerCase()] = true;

    const clips = Object.create(null);       // path -> { slot: { anim, o } }
    const isSyncWorkspot = Object.create(null);
    let handled = 0;

    for (const path of workspots) {
        handled += 1;
        const found = readSyncClips(path);
        if (found) {
            clips[path] = found;
            isSyncWorkspot[path.toLowerCase()] = true;
        }
        if (handled % settings.progressEvery === 0 || handled === workspots.length) {
            logInfo("Workspots " + handled + "/" + workspots.length + " (synced: " + Object.keys(clips).length + ")");
        }
    }
    logInfo("Workspots carrying sync clips: " + Object.keys(clips).length);

    const placements = PLACEMENT_SECTORS.length > 0
        ? readPlacements(isSyncWorkspot)
        : { observed: Object.create(null), masterEdges: Object.create(null) };
    logInfo("Observed couples: " + Object.keys(placements.observed).length + " workspot combinations");
    logInfo("Observed master links: " + Object.keys(placements.masterEdges).length + " workspot combinations");

    // A shared slot with a different clip is the other half of the scene.
    const partners = Object.create(null);
    const bySlot = Object.create(null);
    for (const path of Object.keys(clips)) {
        for (const slot of Object.keys(clips[path])) (bySlot[slot] = bySlot[slot] || []).push(path);
    }
    for (const slot of Object.keys(bySlot)) {
        const group = bySlot[slot];
        for (const a of group) {
            for (const b of group) {
                if (a === b || clips[a][slot].anim === clips[b][slot].anim) continue;
                (partners[a] = partners[a] || Object.create(null))[b] = true;
            }
        }
    }

    const scenePairs = SCENE_FILES.length > 0 ? readScenePairs(listed, isSyncWorkspot) : Object.create(null);
    logInfo("Scene couples: " + Object.keys(scenePairs).length + " workspot combinations");
    for (const key of Object.keys(scenePairs)) {
        const parts = key.split("|");
        (partners[parts[0]] = partners[parts[0]] || Object.create(null))[parts[1]] = true;
    }

    const result = {};
    let links = 0;

    // A workspot reaches the file through its sync clips, or through a scene that pairs it.
    const subjects = Object.create(null);
    for (const path of Object.keys(clips)) subjects[path] = true;
    for (const key of Object.keys(scenePairs)) subjects[key.split("|")[0]] = true;

    for (const a of Object.keys(subjects).sort(compareText)) {
        const entries = [];

        for (const b of Object.keys(partners[a] || {}).sort(compareText)) {
            const ownClips = clips[a] || Object.create(null);
            const otherClips = clips[b] || Object.create(null);
            const shared = Object.keys(ownClips).filter(function (slot) {
                return otherClips[slot] !== undefined && ownClips[slot].anim !== otherClips[slot].anim;
            }).sort(compareText);

            const clusters = clusterObservations(placements.observed[a.toLowerCase() + "|" + b.toLowerCase()]);
            const arrangements = [];

            for (const slot of shared) {
                const own = ownClips[slot].o, other = otherClips[slot].o;
                let o, src;
                if (!isIdentity(own)) { o = own; src = "authored"; }
                else if (!isIdentity(other)) { o = invert(other); src = "authoredInverse"; }
                else { o = [0, 0, 0, 0]; src = "authored"; }

                let n = 0;
                for (const cluster of clusters) if (sameTransform(cluster.centre, o)) n += cluster.n;

                let existing = null;
                for (const arrangement of arrangements) if (sameTransform(arrangement.o, o)) { existing = arrangement; break; }
                if (existing) existing.slots.push(slot);
                else arrangements.push({ slots: [slot], o: o.map(round4), src: src, n: n });
            }

            if (clusters.length > 0 && clusters[0].n >= settings.minMeasuredCount) {
                let explained = false;
                for (const arrangement of arrangements) if (sameTransform(arrangement.o, clusters[0].centre)) { explained = true; break; }
                if (!explained) {
                    arrangements.push({ slots: [], o: clusters[0].centre.map(round4), src: "measured", n: clusters[0].n });
                }
            }

            // Where a shipped scene stages the couple. Only used while nothing else says where
            // the partner goes, since a scene stages one moment of a pair authored for several.
            const scene = scenePairs[a.toLowerCase() + "|" + b.toLowerCase()];
            if (scene) {
                let placed = false;
                for (const arrangement of arrangements) if (!isIdentity(arrangement.o)) { placed = true; break; }
                if (!placed) arrangements.push({ slots: [], o: scene.o, src: "scene", n: scene.n });
            }

            if (arrangements.length === 0) continue;

            arrangements.sort(function (x, y) {
                if (x.n !== y.n) return y.n - x.n;
                if (isIdentity(x.o) !== isIdentity(y.o)) return isIdentity(x.o) ? 1 : -1;
                return compareText(x.slots[0] || "", y.slots[0] || "");
            });

            let vanilla = 0;
            for (const arrangement of arrangements) vanilla += arrangement.n;
            // [times b pointed at a, times a pointed at b] = [a leads, b leads]
            const master = [
                placements.masterEdges[b.toLowerCase() + "|" + a.toLowerCase()] || 0,
                placements.masterEdges[a.toLowerCase() + "|" + b.toLowerCase()] || 0
            ];
            entries.push({ path: b, vanilla: vanilla, master: master, arrangements: arrangements });
            links += 1;
        }

        if (entries.length === 0) continue;
        entries.sort(function (x, y) {
            if (x.vanilla !== y.vanilla) return y.vanilla - x.vanilla;
            // Of two copies of one partner, the one from this workspot's own set comes first.
            const own = pathFamily(a);
            const xOwn = pathFamily(x.path) === own, yOwn = pathFamily(y.path) === own;
            if (xOwn !== yOwn) return xOwn ? -1 : 1;
            return compareText(x.path, y.path);
        });
        result[a.toLowerCase()] = { path: a, partners: entries };
    }

    wkit.SaveToResources(settings.outputPathInResources, JSON.stringify({ version: 1, workspots: result }));

    logInfo("Workspots with partners: " + Object.keys(result).length);
    logInfo("Partner links: " + links);
    logInfo("Output: resources/" + settings.outputPathInResources);
}

// Every shipped sector that places an AI Spot on one of the synced workspots, found with a
// reverse-dependency lookup over the whole archive set (WolvenKit MCP find_references). Emptying
// this list still produces a valid file, but one without the "measured" arrangements and without
// the shipped-usage counts the picker sorts and labels by.
const PLACEMENT_SECTORS = [
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-10_-19_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-11_-14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-11_-15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-11_-16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-11_-17_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-11_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-12_-16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-12_-17_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-12_-18_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-12_-19_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-12_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-12_-21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-13_-17_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-13_-18_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-13_-19_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-13_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-13_-22_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-14_-17_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-14_-18_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-14_-19_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-14_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-14_-21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-14_-22_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-15_-18_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-15_-19_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-15_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-15_-21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-15_-22_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-15_-23_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-16_-19_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-16_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-16_-21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-16_-22_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-16_-23_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-17_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-17_-21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-17_-22_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-17_-23_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-17_-24_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-17_-25_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-18_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-18_-21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-18_-22_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-18_-23_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-18_-24_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-19_-21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-19_-22_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-19_-23_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-20_-21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-20_-22_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-22_-32_1_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-24_-34_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-24_-38_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-25_-35_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-25_-37_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-26_-37_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-27_-36_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-27_2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-27_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-28_-37_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-28_-39_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-28_2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-28_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-29_-43_1_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-29_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-30_-40_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-30_-42_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-35_-42_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-7_-8_0_2.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\exterior_-9_-13_0_2.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_1afdd23ed3159f7e.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_228aee81190d7bc2.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_356664e005c6bb0d.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_5a84a58902a6c2e6.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_654d2e680f7846ca.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_746e38ed6d41094a.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_7abca2b8d18f8562.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_7c45cc4180e4d8fb.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_9a8b085db27b37e6.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_9ecf0f6eee9ee9de.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_ab16925ec21f6bcd.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_ba4d97f846d435ed.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_bb3937b6e34a251c.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_c0c925cd0ad32a5b.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_e1a2ca39daf3e5ef.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_e9046bd77c48793d.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_f34310b5a75b9f1e.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\ep1\\quest_f9f56e7ec2bde6db.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_-2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_0_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-10_9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_-13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_-14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_-1_-1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_-9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-11_9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_-15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_-16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_-9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_17_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-12_9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_-11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_-16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_-3_-1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_-4_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_-7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_0_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-13_9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_-2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_-4_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_-9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_18_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_19_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-14_9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_-11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_-15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_-16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_-3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_0_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_1_-1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-15_5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_-15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_-17_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_-18_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_-2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_-9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-16_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-17_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-17_-15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-17_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-17_11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-17_12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-17_21_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-17_22_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-17_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-18_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-18_-11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-18_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-18_-9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-18_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-1_-13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-1_-14_-1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-1_-15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-1_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-1_-2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-1_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-1_0_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-1_1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-1_2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-20_-18_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-20_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-20_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-21_-19_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-21_-1_-1_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-21_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-22_-19_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-22_15_0_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-23_-20_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-2_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-2_-2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-2_-3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-2_-7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-2_0_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-2_1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-2_2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-2_3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-33_7_1_0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-3_-16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-3_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-3_-2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-3_-4_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-3_0_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-4_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-4_0_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-4_10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-4_4_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-4_6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-4_8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-5_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-5_-2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-5_-3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-5_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-5_1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-5_4_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-5_6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-5_7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-5_8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-6_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-6_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-6_10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-6_14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-6_16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-6_2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-6_6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-6_7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-7_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-7_-4_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-7_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-7_14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-7_1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-7_6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-7_7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-7_9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_-13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_-2_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_-3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_-4_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_-9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-8_13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_-11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_-12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_-13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_-3_-1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_-3_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_-4_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_16_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_-9_9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_0_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_0_-14_-1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_0_-15_-1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_0_-1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_0_-9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_0_0_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_0_1_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_11_-11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_12_-7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_13_-7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_1_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_1_-12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_1_-13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_1_-14_-1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_1_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_1_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_1_-9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_1_4_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_23_-15_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_2_-12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_2_-13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_2_-19_1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_3_-12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_3_-13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_3_-14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_3_-17_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_3_-19_1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_4_-11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_4_-13_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_4_-14_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_4_-17_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_5_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_5_-11_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_5_-12_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_5_-19_1_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_5_-9_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_6_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_7_-10_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_7_-7_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_7_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_8_-6_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_8_-8_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\exterior_9_-5_0_1.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_15451a9f669ffc11.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_1c2f6807c46cb0f0.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_3c581324570fae71.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_3f8368db958a5840.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_4eddbb610b95be36.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_553fb27d7a3783ed.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_65ef8bbcfd3f13e6.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_7f71d61c5e7b3690.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_8c05706865e80755.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_9d4e390918dec5a3.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_9da2b9328cb64d35.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_a0fc15697005ddee.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_b65d6719ac9bf293.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_d9b1b5422f36a8fc.streamingsector",
    "base\\worlds\\03_night_city\\_compiled\\default\\quest_fc8de140a10433c4.streamingsector"
];

// Every shipped scene that holds workspot instances, from one pass over all 4,098 vanilla scenes.
// Emptying this list still produces a valid file, but one without the "scene" arrangements and
// without the quest workspots, which are only ever paired up by a scene.
const SCENE_FILES = [
    "base\\media\\difficulty_selection\\scenes\\difficulty_selection_scene.scene",
    "base\\media\\finalboards\\scenes\\fb_hanako_refused.scene",
    "base\\media\\finalboards\\scenes\\fb_judy.scene",
    "base\\media\\finalboards\\scenes\\fb_judy_nomads_hut.scene",
    "base\\media\\finalboards\\scenes\\fb_kerry.scene",
    "base\\media\\finalboards\\scenes\\fb_misty.scene",
    "base\\media\\finalboards\\scenes\\fb_mitch.scene",
    "base\\media\\finalboards\\scenes\\fb_panam.scene",
    "base\\media\\finalboards\\scenes\\fb_peralez.scene",
    "base\\media\\finalboards\\scenes\\fb_river.scene",
    "base\\media\\finalboards\\scenes\\fb_rogue.scene",
    "base\\media\\finalboards\\scenes\\fb_saul.scene",
    "base\\media\\finalboards\\scenes\\fb_takemura.scene",
    "base\\media\\finalboards\\scenes\\fb_victor.scene",
    "base\\media\\finalboards\\scenes\\fb_welles.scene",
    "base\\media\\intro\\scenes\\sh0200.scene",
    "base\\media\\intro\\scenes\\sh0300_3.scene",
    "base\\media\\intro\\scenes\\sh0400.scene",
    "base\\media\\intro\\scenes\\sh0600.scene",
    "base\\media\\intro\\scenes\\sh0700.scene",
    "base\\media\\intro\\scenes\\sh0800.scene",
    "base\\media\\intro\\scenes\\sh0900.scene",
    "base\\media\\intro\\scenes\\sh1000_2.scene",
    "base\\open_world\\city_scenes\\templates\\noncombat\\cs_garbage_collectors\\cs_garbage_collectors_scene_sync.scene",
    "base\\open_world\\city_scenes\\templates\\noncombat\\cs_gun_suicide\\cs_gun_suicide.scene",
    "base\\open_world\\city_scenes\\templates\\noncombat\\cs_homeless_trashcan\\cs_homeless_trashcan_player_scene.scene",
    "base\\open_world\\community\\e3_2019\\scenes\\e3_q110_warehouse_chat.scene",
    "base\\open_world\\community\\watson\\little_china\\wat_lch_afterlife_bouncer.scene",
    "base\\open_world\\fixers\\dakota\\scenes\\dakota_smith_defaut.scene",
    "base\\open_world\\fixers\\dyno\\scenes\\dyno_default.scene",
    "base\\open_world\\fixers\\el_capitan\\scenes\\muamar_reyes_default.scene",
    "base\\open_world\\fixers\\padre\\scenes\\padre_default.scene",
    "base\\open_world\\fixers\\reggie\\scenes\\reggie_default.scene",
    "base\\open_world\\fixers\\wakako\\scenes\\wakako_okada_default.scene",
    "base\\open_world\\metro\\ue_metro\\scenes\\ue_metro_01_train_ride.scene",
    "base\\open_world\\metro\\ue_metro\\scenes\\ue_metro_03_generic_passengers.scene",
    "base\\open_world\\metro\\ue_metro\\scenes\\ue_metro_03_generic_passengers_2.scene",
    "base\\open_world\\mini_world_stories\\badlands\\se5\\mws_se5_07\\scenes\\mws_se5_07.scene",
    "base\\open_world\\mini_world_stories\\badlands\\se5\\mws_se5_07\\scenes\\mws_se5_07_camp.scene",
    "base\\open_world\\mini_world_stories\\city_center\\mws_cc_01\\scenes\\mws_cc_01_vending_shock.scene",
    "base\\open_world\\mini_world_stories\\heywood\\mws_hey_02\\scenes\\mws_hey_02_scene.scene",
    "base\\open_world\\mini_world_stories\\heywood\\mws_hey_04\\scenes\\mws_hey_04_rave.scene",
    "base\\open_world\\mini_world_stories\\pacifica\\mws_pac_01\\scenes\\mws_pac_01.scene",
    "base\\open_world\\mini_world_stories\\watson\\mws_wat_01\\scenes\\mws_wat_01.scene",
    "base\\open_world\\mini_world_stories\\watson\\mws_wat_02\\scenes\\mws_wat_02.scene",
    "base\\open_world\\mini_world_stories\\watson\\mws_wat_08\\scenes\\mws_wat_08.scene",
    "base\\open_world\\mini_world_stories\\westbrook\\mws_wbr_01\\scenes\\mws_wbr_01.scene",
    "base\\open_world\\minor_activities\\city_center\\downtown\\ma_cct_dtn_03\\scenes\\ma_cct_dtn_03_scenes.scene",
    "base\\open_world\\minor_activities\\watson\\kabuki\\ma_wat_kab_02\\scenes\\ma_wat_kab_02.scene",
    "base\\open_world\\minor_activities\\watson\\kabuki\\ma_wat_kab_08\\scenes\\ma_wat_kab_08_johnny_and_clues.scene",
    "base\\open_world\\minor_activities\\watson\\little_china\\ma_wat_lch_06\\scenes\\ma_wat_lch_06_clues_n_mood.scene",
    "base\\open_world\\minor_activities\\watson\\northside\\ma_wat_nid_03\\scenes\\ma_wat_nid_03_scene.scene",
    "base\\open_world\\minor_activities\\watson\\northside\\ma_wat_nid_15\\scenes\\ma_wat_nid_15_investigation.scene",
    "base\\open_world\\scenes\\dancefloors\\dancefloor_7th_hell.scene",
    "base\\open_world\\scenes\\dancefloors\\dancefloor_atlantis.scene",
    "base\\open_world\\scenes\\dancefloors\\dancefloor_cs_goons_rave_party.scene",
    "base\\open_world\\scenes\\dancefloors\\dancefloor_empathy.scene",
    "base\\open_world\\scenes\\dancefloors\\dancefloor_riot.scene",
    "base\\open_world\\scenes\\dancefloors\\dancefloor_totentanz.scene",
    "base\\open_world\\scenes\\lore_animations\\la_execution_01.scene",
    "base\\open_world\\scenes\\lore_animations\\la_execution_02.scene",
    "base\\open_world\\scenes\\lore_animations\\la_execution_03.scene",
    "base\\open_world\\scenes\\lore_animations\\la_gang_hostilities_01.scene",
    "base\\open_world\\scenes\\lore_animations\\la_organ_harvesting_01.scene",
    "base\\open_world\\scenes\\lore_animations\\la_robbery_01.scene",
    "base\\open_world\\scenes\\lore_animations\\la_robbery_02.scene",
    "base\\open_world\\scenes\\lore_animations\\la_sexual_violence_01.scene",
    "base\\open_world\\scenes\\lore_animations\\la_street_violence_01.scene",
    "base\\open_world\\scenes\\lore_animations\\la_street_violence_02.scene",
    "base\\open_world\\scenes\\lore_animations\\la_street_violence_03.scene",
    "base\\open_world\\scenes\\ma_scenes\\ma_scene_searching_01.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_abandoned_motel.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_afterlife.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_anthonys_bathroom.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_braindance_studio.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_claire_garage.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_dollhouse.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_el_cojote.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_ep1_pyramid.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_ep1_pyramid_malebathroom.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_ep1_spaceport.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_farmhouse.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_fingers.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_joss_trailer.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_judys_apartment.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_kerrys_villa.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_konpeki_room.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_lizzies.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_new_nomad_camp.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_old_nomad_camp.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_pac_wwd_melee_01.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_peralez_penthouse.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_piez.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_police_lab.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_randys_trailer.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_red_dirt.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_riot.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_shady_ripper.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_cct_dtn_02.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_cct_dtn_04.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_cct_dtn_04_main.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_hey_gle_03.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_hey_gle_04_01.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_hey_gle_04_02.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_hey_rey_02.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_hey_rey_06.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_hey_rey_08.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_hey_spr_06.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_pac_wwd_05.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_std_rcr_01_01.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_wat_kab_04.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_wat_lch_03_01.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_wat_lch_03_02.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_wat_nid_03.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sts_wbr_hil_01.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sunset_panam.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_sunset_single.scene",
    "base\\open_world\\scenes\\mirrors\\mirror_scene_v_penthouse.scene",
    "base\\open_world\\scenes\\sts_characters\\aaron_mccarlson_default.scene",
    "base\\open_world\\scenes\\sts_characters\\anna_hamill_default.scene",
    "base\\open_world\\scenes\\sts_characters\\dan_default.scene",
    "base\\open_world\\scenes\\sts_characters\\lucy_thackery_default.scene",
    "base\\open_world\\scenes\\sts_characters\\max_jones_default.scene",
    "base\\open_world\\scenes\\sts_characters\\tiny_mike_default.scene",
    "base\\open_world\\scenes\\ue_cats\\city_center\\wst_cat_dtn_01_scene.scene",
    "base\\open_world\\street_stories\\badlands\\inland_avenue\\sts_bls_ina_02\\scenes\\sts_bls_ina_02_big_pete_scene.scene",
    "base\\open_world\\street_stories\\badlands\\inland_avenue\\sts_bls_ina_05\\scenes\\sts_bls_ina_05_archibald.scene",
    "base\\open_world\\street_stories\\badlands\\inland_avenue\\sts_bls_ina_05\\scenes\\sts_bls_ina_05_bruce.scene",
    "base\\open_world\\street_stories\\badlands\\inland_avenue\\sts_bls_ina_06\\scenes\\sts_bls_ina_06_01_hostage.scene",
    "base\\open_world\\street_stories\\badlands\\inland_avenue\\sts_bls_ina_06\\scenes\\sts_bls_ina_06_meeting_dakota.scene",
    "base\\open_world\\street_stories\\badlands\\inland_avenue\\sts_bls_ina_09\\scenes\\sts_bls_ina_09_benedict.scene",
    "base\\open_world\\street_stories\\badlands\\inland_avenue\\sts_bls_ina_09\\scenes\\sts_bls_ina_09_jason.scene",
    "base\\open_world\\street_stories\\badlands\\inland_avenue\\sts_bls_ina_09\\scenes\\sts_bls_ina_09_meeting_nomad.scene",
    "base\\open_world\\street_stories\\city_center\\corpo_plaza\\sts_cct_cpz_01\\scenes\\sts_cct_cpz_01_guards_chat.scene",
    "base\\open_world\\street_stories\\city_center\\corpo_plaza\\sts_cct_cpz_01\\scenes\\sts_cct_cpz_01_prisoner_chat.scene",
    "base\\open_world\\street_stories\\city_center\\downtown\\sts_cct_dtn_02\\scenes\\sts_cct_dtn_02_bouncer_main_door.scene",
    "base\\open_world\\street_stories\\city_center\\downtown\\sts_cct_dtn_02\\scenes\\sts_cct_dtn_02_johnny.scene",
    "base\\open_world\\street_stories\\city_center\\downtown\\sts_cct_dtn_02\\scenes\\sts_cct_dtn_02_red_thunder.scene",
    "base\\open_world\\street_stories\\city_center\\downtown\\sts_cct_dtn_02\\scenes\\sts_cct_dtn_02_vip_bouncer_001.scene",
    "base\\open_world\\street_stories\\city_center\\downtown\\sts_cct_dtn_03\\scenes\\sts_cct_dtn_03_guard_scene_before_security_room.scene",
    "base\\open_world\\street_stories\\city_center\\downtown\\sts_cct_dtn_03\\scenes\\sts_cct_dtn_03_main_scene.scene",
    "base\\open_world\\street_stories\\city_center\\downtown\\sts_cct_dtn_04\\scenes\\sts_cct_dtn_04_receptionist.scene",
    "base\\open_world\\street_stories\\city_center\\downtown\\sts_cct_dtn_04\\scenes\\sts_cct_dtn_04_target_elimination.scene",
    "base\\open_world\\street_stories\\heywood\\glenn\\sts_hey_gle_01\\scenes\\sts_hey_gle_01_tucker.scene",
    "base\\open_world\\street_stories\\heywood\\glenn\\sts_hey_gle_03\\scenes\\sts_hey_gle_03_scene.scene",
    "base\\open_world\\street_stories\\heywood\\glenn\\sts_hey_gle_04\\scenes\\sts_hey_gle_04_bouncer.scene",
    "base\\open_world\\street_stories\\heywood\\glenn\\sts_hey_gle_04\\scenes\\sts_hey_gle_04_johnny.scene",
    "base\\open_world\\street_stories\\heywood\\glenn\\sts_hey_gle_05\\scenes\\sts_hey_gle_05_el_gallo_conversation.scene",
    "base\\open_world\\street_stories\\heywood\\glenn\\sts_hey_gle_06\\scenes\\sts_hey_gle_06_scene.scene",
    "base\\open_world\\street_stories\\heywood\\vista_del_rey\\sts_hey_rey_01\\scenes\\sts_hey_rey_01_03_gustavo.scene",
    "base\\open_world\\street_stories\\heywood\\vista_del_rey\\sts_hey_rey_02\\scenes\\sts_hey_rey_02_gangers.scene",
    "base\\open_world\\street_stories\\heywood\\vista_del_rey\\sts_hey_rey_06\\scenes\\sts_hey_rey_06_receptionist.scene",
    "base\\open_world\\street_stories\\heywood\\vista_del_rey\\sts_hey_rey_09\\scenes\\sts_hey_rey_09_04_tobias.scene",
    "base\\open_world\\street_stories\\santo_domingo\\arroyo\\sts_std_arr_01\\scenes\\new_scenes\\sts_std_arr_01_cleaner_new.scene",
    "base\\open_world\\street_stories\\santo_domingo\\arroyo\\sts_std_arr_01\\scenes\\new_scenes\\sts_std_arr_01_recepctionist_new.scene",
    "base\\open_world\\street_stories\\santo_domingo\\arroyo\\sts_std_arr_01\\scenes\\new_scenes\\sts_std_arr_01_room_new.scene",
    "base\\open_world\\street_stories\\santo_domingo\\arroyo\\sts_std_arr_05\\scenes\\sts_std_arr_05_fox_talk.scene",
    "base\\open_world\\street_stories\\santo_domingo\\arroyo\\sts_std_arr_06\\scenes\\sts_std_arr_06_scn.scene",
    "base\\open_world\\street_stories\\santo_domingo\\arroyo\\sts_std_arr_12\\scenes\\sts_std_arr_12_diner_scene.scene",
    "base\\open_world\\street_stories\\santo_domingo\\arroyo\\sts_std_arr_12\\scenes\\sts_std_arr_12_pedro.scene",
    "base\\open_world\\street_stories\\santo_domingo\\rancho_corronado\\sts_std_rcr_01\\scenes\\sts_std_rcr_01_scene.scene",
    "base\\open_world\\street_stories\\santo_domingo\\rancho_corronado\\sts_std_rcr_02\\scenes\\sts_std_rcr_02_dixon.scene",
    "base\\open_world\\street_stories\\santo_domingo\\rancho_corronado\\sts_std_rcr_02\\scenes\\sts_std_rcr_02_johnny.scene",
    "base\\open_world\\street_stories\\santo_domingo\\rancho_corronado\\sts_std_rcr_02\\scenes\\sts_std_rcr_02_reception.scene",
    "base\\open_world\\street_stories\\santo_domingo\\rancho_corronado\\sts_std_rcr_03\\scenes\\sts_std_rcr_03_gangers.scene",
    "base\\open_world\\street_stories\\santo_domingo\\rancho_corronado\\sts_std_rcr_03\\scenes\\sts_std_rcr_03_investigation.scene",
    "base\\open_world\\street_stories\\santo_domingo\\rancho_corronado\\sts_std_rcr_03\\scenes\\sts_std_rcr_03_meeting_hayashi.scene",
    "base\\open_world\\street_stories\\santo_domingo\\rancho_corronado\\sts_std_rcr_03\\scenes\\sts_std_rcr_03_meeting_nomad.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_01\\scenes\\sts_wat_kab_01_bouncer.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_01\\scenes\\sts_wat_kab_01_chat_003.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_01\\scenes\\sts_wat_kab_01_chat_05.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_01\\scenes\\sts_wat_kab_01_dirtboys.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_01\\scenes\\sts_wat_kab_01_tiny_mike.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_01\\scenes\\sts_wat_kab_01_tiny_mike_ground_floor.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_01\\scenes\\sts_wat_kab_01_tiny_mike_restaurant.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_02\\scenes\\sts_wat_kab_02_scene.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_03\\scenes\\sts_wat_kab_03_johnny.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_03\\scenes\\sts_wat_kab_03_scene.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_04\\scenes\\sts_wat_kab_04_give_the_shard.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_04\\scenes\\sts_wat_kab_04_receptionist.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_05\\scenes\\sts_wat_kab_05_ripperdoc.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_08\\scenes\\sts_wat_kab_08_dave_hamill.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_08\\scenes\\sts_wat_kab_08_food_chat.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_08\\scenes\\sts_wat_kab_08_food_courier.scene",
    "base\\open_world\\street_stories\\watson\\kabuki\\sts_wat_kab_08\\scenes\\sts_wat_kab_08_prostitute.scene",
    "base\\open_world\\street_stories\\watson\\little_china\\sts_wat_lch_03\\scenes\\sts_wat_lch_03_ricky_wu.scene",
    "base\\open_world\\street_stories\\watson\\little_china\\sts_wat_lch_05\\scenes\\sts_wat_lch_05_johnny.scene",
    "base\\open_world\\street_stories\\watson\\northside_industrial_district\\sts_wat_nid_01\\scenes\\sts_wat_nid_01_hal.scene",
    "base\\open_world\\street_stories\\watson\\northside_industrial_district\\sts_wat_nid_01\\scenes\\sts_wat_nid_01_lizzie.scene",
    "base\\open_world\\street_stories\\watson\\northside_industrial_district\\sts_wat_nid_03\\scenes\\sts_wat_nid_03_haruo.scene",
    "base\\open_world\\street_stories\\watson\\northside_industrial_district\\sts_wat_nid_04\\scenes\\sts_wat_nid_04_gottfrid_fredrik.scene",
    "base\\open_world\\street_stories\\watson\\northside_industrial_district\\sts_wat_nid_07\\scenes\\sts_wat_nid_07_aaron_mccarlson.scene",
    "base\\open_world\\street_stories\\watson\\northside_industrial_district\\sts_wat_nid_07\\scenes\\sts_wat_nid_07_recording_scene.scene",
    "base\\open_world\\street_stories\\watson\\northside_industrial_district\\sts_wat_nid_12\\scenes\\sts_wat_nid_12_max_jones.scene",
    "base\\open_world\\street_stories\\westbrook\\charter_hill\\sts_wbr_hil_07\\scenes\\sts_wbr_hil_07.scene",
    "base\\open_world\\street_stories\\westbrook\\japantown\\sts_wbr_jpn_01\\scenes\\sts_wbr_jpn_01_alex.scene",
    "base\\open_world\\street_stories\\westbrook\\japantown\\sts_wbr_jpn_01\\scenes\\sts_wbr_jpn_01_meeting_sergei.scene",
    "base\\open_world\\street_stories\\westbrook\\japantown\\sts_wbr_jpn_02\\scenes\\sts_wbr_jpn_02_lauren.scene",
    "base\\open_world\\street_stories\\westbrook\\japantown\\sts_wbr_jpn_05\\scenes\\sts_wbr_jpn_05_johnny.scene",
    "base\\open_world\\street_stories\\westbrook\\japantown\\sts_wbr_jpn_05\\scenes\\sts_wbr_jpn_05_ren_cheng.scene",
    "base\\open_world\\street_stories\\westbrook\\japantown\\sts_wbr_jpn_09\\scenes\\sts_wbr_jpn_09_netrunner.scene",
    "base\\open_world\\vendors\\badlands\\inland_avenue_se1\\bls_ina_se1_foodshop_01\\bls_ina_se1_foodshop_01.scene",
    "base\\open_world\\vendors\\badlands\\inland_avenue_se1\\bls_ina_se1_gunsmith_01\\bls_ina_se1_gunsmith_01.scene",
    "base\\open_world\\vendors\\badlands\\inland_avenue_se1\\bls_ina_se1_junkshop_01\\bls_ina_se1_junkshop_01.scene",
    "base\\open_world\\vendors\\badlands\\inland_avenue_se1\\bls_ina_se1_ripperdoc_01\\bls_ina_se1_ripperdoc_01.scene",
    "base\\open_world\\vendors\\badlands\\inland_avenue_se5\\bls_ina_se5_foodshop_01\\bls_ina_se5_foodshop_01.scene",
    "base\\open_world\\vendors\\city_center\\corpo_plaza\\cct_cpz_cloth_02\\cct_cpz_cloth_02.scene",
    "base\\open_world\\vendors\\city_center\\corpo_plaza\\cct_cpz_food_01\\cct_cpz_food_01.scene",
    "base\\open_world\\vendors\\city_center\\corpo_plaza\\cct_cpz_food_02\\cct_cpz_food_02.scene",
    "base\\open_world\\vendors\\city_center\\corpo_plaza\\cct_cpz_medic_01\\cct_cpz_medic_01.scene",
    "base\\open_world\\vendors\\city_center\\downtown\\cct_dtn_cloth_01\\cct_dtn_cloth_01.scene",
    "base\\open_world\\vendors\\city_center\\downtown\\cct_dtn_food_01\\cct_dtn_food_01.scene",
    "base\\open_world\\vendors\\city_center\\downtown\\cct_dtn_food_02\\cct_dtn_food_02.scene",
    "base\\open_world\\vendors\\city_center\\downtown\\cct_dtn_medic_01\\cct_dtn_medic_01.scene",
    "base\\open_world\\vendors\\city_center\\downtown\\cct_dtn_ripdoc_01\\cct_dtn_ripdoc_01.scene",
    "base\\open_world\\vendors\\heywood\\glen\\hey_gle_foodshop_01\\hey_gle_foodshop_01.scene",
    "base\\open_world\\vendors\\heywood\\glen\\hey_gle_foodshop_02\\hey_gle_foodshop_02.scene",
    "base\\open_world\\vendors\\heywood\\glen\\hey_gle_gunsmith_01\\hey_gle_gunsmith_01.scene",
    "base\\open_world\\vendors\\heywood\\glen\\hey_gle_prostitue_male\\hey_gle_prostitute_male.scene",
    "base\\open_world\\vendors\\heywood\\glen\\hey_gle_prostitute_female\\hey_gle_prostitute_female.scene",
    "base\\open_world\\vendors\\heywood\\vista_del_rey\\hey_rey_foodshop_01\\elcoyote_barman_default.scene",
    "base\\open_world\\vendors\\heywood\\vista_del_rey\\hey_rey_foodshop_02\\hey_rey_foodshop_02.scene",
    "base\\open_world\\vendors\\heywood\\vista_del_rey\\hey_rey_foodshop_03\\hey_rey_foodshop_03.scene",
    "base\\open_world\\vendors\\heywood\\vista_del_rey\\hey_rey_gunsmith_01\\hey_rey_gunsmith_01.scene",
    "base\\open_world\\vendors\\heywood\\vista_del_rey\\hey_rey_junkshop_01\\hey_rey_junkshop_01.scene",
    "base\\open_world\\vendors\\heywood\\vista_del_rey\\hey_rey_netrunner_01\\hey_rey_netrunner_01.scene",
    "base\\open_world\\vendors\\heywood\\wellsprings\\hey_spr_gunsmith_01\\hey_spr_gunsmith_01.scene",
    "base\\open_world\\vendors\\heywood\\wellsprings\\hey_spr_junk_01\\hey_spr_junk_01.scene",
    "base\\open_world\\vendors\\heywood\\wellsprings\\hey_spr_medicstore_01\\hey_spr_medicstore_01.scene",
    "base\\open_world\\vendors\\heywood\\wellsprings\\hey_spr_ripperdoc_01\\hey_spr_ripperdoc_01.scene",
    "base\\open_world\\vendors\\pacifica\\coastview\\pac_civ_techstore_01\\pac_cvi_techstore_01.scene",
    "base\\open_world\\vendors\\pacifica\\coastview\\pac_cvi_medicstore_01\\pac_cvi_medicstore_01.scene",
    "base\\open_world\\vendors\\pacifica\\west_wind_estate\\pac_wwd_ripdoc_01\\pac_wwd_ripdoc_01.scene",
    "base\\open_world\\vendors\\santo_domingo\\arroyo\\std_arr_foodshop_01\\std_arr_foodshop_01.scene",
    "base\\open_world\\vendors\\santo_domingo\\arroyo\\std_arr_foodshop_02\\std_arr_foodshop_02.scene",
    "base\\open_world\\vendors\\santo_domingo\\arroyo\\std_arr_medicstore_01\\std_arr_medicstore_01.scene",
    "base\\open_world\\vendors\\santo_domingo\\arroyo\\std_arr_ripperdoc_01\\std_arr_ripperdoc_01.scene",
    "base\\open_world\\vendors\\santo_domingo\\rancho_coronado\\std_rcr_clothingshop_01\\std_rcr_clothingshop_01.scene",
    "base\\open_world\\vendors\\santo_domingo\\rancho_coronado\\std_rcr_foodshop_01\\std_rcr_foodshop_01.scene",
    "base\\open_world\\vendors\\santo_domingo\\rancho_coronado\\std_rcr_ripperdoc_01\\std_rcr_ripperdoc_01.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_foodshop_02\\wat_kab_foodshop_02.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_foodshop_03\\wat_kab_foodshop_03.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_foodshop_04\\wat_kab_foodshop_04.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_gunsmith_02\\wat_kab_gunsmith_02.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_junkshop_01\\wat_kab_junkshop_01.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_medicstore_01\\wat_kab_medicstore_01.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_netrunner_01\\wat_kab_netrunner_01.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_ripperdoc_01\\wat_kab_ripperdoc_01.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_ripperdoc_02\\wat_kab_ripperdoc_02.scene",
    "base\\open_world\\vendors\\watson\\kabuki\\wat_kab_ripperdoc_03\\wat_kab_ripperdoc_03_ok.scene",
    "base\\open_world\\vendors\\watson\\little_china\\wat_lch_clothingshop_01\\wat_lch_clothingshop_01.scene",
    "base\\open_world\\vendors\\watson\\little_china\\wat_lch_foodshop_02\\wat_lch_foodshop_02.scene",
    "base\\open_world\\vendors\\watson\\little_china\\wat_lch_foodshop_03\\wat_lch_foodshop_03.scene",
    "base\\open_world\\vendors\\watson\\little_china\\wat_lch_gunsmith_01\\wat_lch_gunsmith_01.scene",
    "base\\open_world\\vendors\\watson\\little_china\\wat_lch_medicstore_01\\wat_lch_medicstore_01.scene",
    "base\\open_world\\vendors\\watson\\little_china\\wat_lch_melee_01\\wat_lch_melee_01.scene",
    "base\\open_world\\vendors\\watson\\northside\\wat_nid_foodshop_02\\wat_nid_foodshop_02.scene",
    "base\\open_world\\vendors\\watson\\northside\\wat_nid_medicstore_01\\wat_nid_medicstore_01.scene",
    "base\\open_world\\vendors\\watson\\northside\\wat_nid_medicstore_02\\wat_nid_medicstore_02.scene",
    "base\\open_world\\vendors\\watson\\northside\\wat_nid_ripperdoc_01\\wat_nid_ripperdoc_01.scene",
    "base\\open_world\\vendors\\westbrook\\charter_hill\\wbr_hil_clothingshop_01\\wbr_hil_clothingshop_01.scene",
    "base\\open_world\\vendors\\westbrook\\charter_hill\\wbr_hil_foodshop_01\\wbr_hil_foodshop_01.scene",
    "base\\open_world\\vendors\\westbrook\\charter_hill\\wbr_hil_foodshop_02\\wbr_hil_foodshop_02.scene",
    "base\\open_world\\vendors\\westbrook\\charter_hill\\wbr_hil_ripdoc_01\\wbr_hil_ripdoc_01.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_cloth_01\\wbr_jpn_cloth_01.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_food_01\\wbr_jpn_food_01.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_food_02\\wbr_jpn_food_02.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_food_03\\wbr_jpn_food_03.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_food_04\\wbr_jpn_food_04.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_food_05\\wbr_jpn_food_05.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_junk_01\\wbr_jpn_junk_01.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_junk_02\\wbr_jpn_junk_02.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_junk_03\\wbr_jpn_junk_03.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_medic_01\\wbr_jpn_medic_01.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_melee_01\\wbr_jpn_melee_01.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_netrun_01\\wbr_jpn_netrun_01.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_netrun_02\\wbr_jpn_netrun_02.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_prostitute_female\\wbr_jpn_prostitute_female.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_prostitute_male\\wbr_jpn_prostitute_male.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_ripdoc_01\\wbr_jpn_ripdoc_01.scene",
    "base\\open_world\\vendors\\westbrook\\japantown\\wbr_jpn_ripdoc_02\\wbr_jpn_ripdoc_02.scene",
    "base\\quest\\holocalls\\holofixer\\holofixer_scene.scene",
    "base\\quest\\main_quests\\epilogue\\q201\\scenes\\q201_01_cyberspace.scene",
    "base\\quest\\main_quests\\epilogue\\q201\\scenes\\q201_02_operation_room.scene",
    "base\\quest\\main_quests\\epilogue\\q201\\scenes\\q201_03_cabin_day_1.scene",
    "base\\quest\\main_quests\\epilogue\\q201\\scenes\\q201_04_cabin_day_2.scene",
    "base\\quest\\main_quests\\epilogue\\q201\\scenes\\q201_06_cabin_day_8_to_29.scene",
    "base\\quest\\main_quests\\epilogue\\q201\\scenes\\q201_07_cabin_day_30.scene",
    "base\\quest\\main_quests\\epilogue\\q201\\scenes\\q201_08_cabin_day_30_takemura.scene",
    "base\\quest\\main_quests\\epilogue\\q202\\scenes\\q202_01_motel.scene",
    "base\\quest\\main_quests\\epilogue\\q202\\scenes\\q202_04a_badlands_travel.scene",
    "base\\quest\\main_quests\\epilogue\\q202\\scenes\\q202_05_convoy.scene",
    "base\\quest\\main_quests\\epilogue\\q202\\scenes\\q202_06_border_running.scene",
    "base\\quest\\main_quests\\epilogue\\q203\\scenes\\q203_01_wakeup.scene",
    "base\\quest\\main_quests\\epilogue\\q203\\scenes\\q203_02_shower.scene",
    "base\\quest\\main_quests\\epilogue\\q203\\scenes\\q203_02b_kerry.scene",
    "base\\quest\\main_quests\\epilogue\\q203\\scenes\\q203_02c_judy.scene",
    "base\\quest\\main_quests\\epilogue\\q203\\scenes\\q203_02d_panam.scene",
    "base\\quest\\main_quests\\epilogue\\q203\\scenes\\q203_03_sobchak.scene",
    "base\\quest\\main_quests\\epilogue\\q203\\scenes\\q203_04_delamain.scene",
    "base\\quest\\main_quests\\epilogue\\q203\\scenes\\q203_05_afterlife.scene",
    "base\\quest\\main_quests\\epilogue\\q203\\scenes\\q203_06_cosmos.scene",
    "base\\quest\\main_quests\\epilogue\\q204\\scenes\\q204_01_waking_up.scene",
    "base\\quest\\main_quests\\epilogue\\q204\\scenes\\q204_02_at_steves.scene",
    "base\\quest\\main_quests\\epilogue\\q204\\scenes\\q204_03_steves_dad.scene",
    "base\\quest\\main_quests\\epilogue\\q204\\scenes\\q204_03b_after_dad.scene",
    "base\\quest\\main_quests\\epilogue\\q204\\scenes\\q204_04_to_music_store.scene",
    "base\\quest\\main_quests\\epilogue\\q204\\scenes\\q204_05_buying_guitar.scene",
    "base\\quest\\main_quests\\epilogue\\q204\\scenes\\q204_06_to_columbarium.scene",
    "base\\quest\\main_quests\\epilogue\\q204\\scenes\\q204_08_farewell.scene",
    "base\\quest\\main_quests\\epilogue\\q204\\scenes\\q204_09_bus_station.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_01_covered_in_trash.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_02_vision_and_sobchuk.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_03_car_ride.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_05_after_crash.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_06_delamain_ride.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_06c_memories_backalley_p1.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_06c_memories_p1.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_06c_memories_p2.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_06c_memories_p3.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_06ca_memories_p2_evac.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_07_ripperdoc.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_07b_whiteroom.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_07c_johnny_triggers.scene",
    "base\\quest\\main_quests\\part1\\q101\\scenes\\q101_08_takemura_v_room.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_02_afterlife_intro.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_03_rogue.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_06_meet_panam.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_06a_camp_drive.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_06b_nomad_camp.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_07_ghost_town_drive.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_08_ghost_town_plan.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_09_raffen_shiv.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_10_escape.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_11_tunnel_drive.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_12_tunnel_ambush.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_13_roadhouse_drive.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_14_maelstrom.scene",
    "base\\quest\\main_quests\\part1\\q103\\scenes\\q103_15_roadhouse_bar.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_01a_roadhouse_meeting.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_01b_calibration.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_02_av_shotdown.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_02a_breaking_antenna.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_03_av_chasing.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_04_nomad_hurt.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_05_av_debris.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_07_gas_station_chats.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_07b_haru_found.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_07c_nomads_arrive.scene",
    "base\\quest\\main_quests\\part1\\q104\\scenes\\q104_08_courier_talks.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_00_holocall_judy.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_01_lizzies.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_01a_bouncer.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_01b_barman.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_01c_lizzies_boss.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_02_lizzy_meet_judy.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_02c_to_dollhouse.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_03_dollhouse_mood.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_03a_dollhouse_doll_01.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_03a_dollhouse_doll_02.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_03a_dollhouse_manager.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_03b_dollhouse_tom.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_03c_dollhouse_woodman.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_03d_dollhouse_investigation.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_03e_dollhouse_leave.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_04_jigjig_street.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_04a_judy_holocall.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_04b_bar.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_04c_braindance_dealer.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_05_fingers_enter.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_06a_fingers_escape.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_06b_fingers_interrogation.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_06c_finding_studio.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_06d_fixer_holocall.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_07_judy_braindance.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_08a_braindance_investigation.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_08d_braindance_gameplay.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_09_braindance_evelyn.scene",
    "base\\quest\\main_quests\\part1\\q105\\scenes\\q105_11_judys_evelyn.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_02_backstage.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_04_exit.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_05_backalley.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_09_taken.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_10_ripper.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_11_thompson.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_13_atlantis_memory.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_14_rogue.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_14b_lift.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_15b_parking.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_15c_car_chase.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_15d_alley.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_18a_lift.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_18c_mainframe_access.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_19_soulkiller.scene",
    "base\\quest\\main_quests\\part1\\q108\\scenes\\q108_21_finale.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_00_fixer.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_01_sermon.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_02_placide.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_03_market.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_04_netrunners_den.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_06_the_mall_intro.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_08a_agent.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_09a_lookout_intercept.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_09b_guards.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_09c_confrontation.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_12_voodoo_queen.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_13_alt_intro.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_14_alt.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_15_vdb_fight.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_16b_closing_funeral.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_ow_fluff_garage_area.scene",
    "base\\quest\\main_quests\\part1\\q110\\scenes\\q110_ow_fluff_gym.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_00b_secret_meeting.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_00c_wakako.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_01_market.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_01_market_02.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_03_reconnaissance.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_04_takemura.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_05_infiltration.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_05c_guard_fluff.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_06b_parade_meeting.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_07a_parade_gameplay_and_combat_routines.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_08_parade_speech.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_09_parade_abduction.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_10_safe_house.scene",
    "base\\quest\\main_quests\\part1\\q112\\scenes\\q112_11_shotgun.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_03a_haru_kasai_drive.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_04_hanako_estate.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_05_av_flight.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_06_saburo_office.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_07_mikoshi.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_09_jungle_start.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_10_jungle_combat.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_11_top_atrium.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_13_adam_smasher.scene",
    "base\\quest\\main_quests\\part1\\q113\\scenes\\q113_14_yorinobu.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_02_saul_sitrep.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_03a_panzer.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_03b_training.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_03c_dakota_trailer.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_03d_alt_meeting.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_04_initiation.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_04b_party.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_05_quiet_place.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_08_morning.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_09_convoy.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_09a_construction.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_10_tunnel.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_10_tunnel_driller.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_11_arasaka_manufacturing_infiltration.scene",
    "base\\quest\\main_quests\\part1\\q114\\scenes\\q114_13_alt_plugged_in.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_00_johnny.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_00b_hanako.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_02_ripperdoc.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_02b_ripperdoc_roof.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_02c_holocalls.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_02d_misty.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_03_rogue.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_03a_alt.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_04_plan.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_04_preparations_final.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_05_halo_jump.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_06_regroup.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_09_security_level.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_11_netrunners_nest.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_12b_tower_lobby.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_12c_tower_nest.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_12d_mikoshi.scene",
    "base\\quest\\main_quests\\part1\\q115\\scenes\\q115_13_vista.scene",
    "base\\quest\\main_quests\\part1\\q116\\scenes\\q116_01_adam_smasher.scene",
    "base\\quest\\main_quests\\part1\\q116\\scenes\\q116_03b_after_bossfight.scene",
    "base\\quest\\main_quests\\part1\\q116\\scenes\\q116_04_mikoshi_intro.scene",
    "base\\quest\\main_quests\\part1\\q116\\scenes\\q116_05_mikoshi.scene",
    "base\\quest\\main_quests\\part1\\q116\\scenes\\q116_05a_ripperdoc_roof.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_corpo_01_security_gate.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_corpo_01a_lobby_chats.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_corpo_02_to_elevators.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_corpo_03_jenkins.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_corpo_03a_office_chats.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_corpo_03b_fly_to_lizzies.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_corpo_04_lizzies_club.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_kid_01a_bar_activities.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_kid_01b_meet_your_fixer.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_kid_01c_car.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_kid_02_fixer_calls.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_kid_02a_confront_jackie.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_kid_03_back_to_bar.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_nomad_01_garage.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_nomad_01b_roadhouse_chats.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_nomad_02_fixer.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_nomad_03_jackie.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_nomad_04_drive_to_border.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_nomad_05_border_crossing.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_nomad_05b_border_chats.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_nomad_07_hideout.scene",
    "base\\quest\\main_quests\\prologue\\q000\\scenes\\q000_vr_tutorial.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_00a_before_mission.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_00aa_jackie_hide_body_tutorial.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_00b_dead_girl.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_00c_rescuing_girl.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_00cd_boss_clean.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_00d_leaving.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_00f_ride_with_jackie.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_00ff_max_tac.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_00g_broken_gate.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_01_wakeup.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_02a_fistfight_tutorial.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_03a_jackie_dex_intro.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_03a_meet_jackie_downstairs.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_04_ripperdoc.scene",
    "base\\quest\\main_quests\\prologue\\q001\\scenes\\q001_04a_rd_assistant.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_01_call_militech.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_01a_militech.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_01b_meat_factory.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_02_maelstrom_corridor.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_02_maelstrom_corridor_part2.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_02_no_deal.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_03_deal.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_03a_militech_invades.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_04d_shootout_militech.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_05_transition.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_07_final.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_07a_final_corp.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_07aa_final_traitor.scene",
    "base\\quest\\main_quests\\prologue\\q003\\scenes\\q003_08_stout.scene",
    "base\\quest\\main_quests\\prologue\\q004\\scenes\\q004_00_lizzies_nightclub_mood_scenes.scene",
    "base\\quest\\main_quests\\prologue\\q004\\scenes\\q004_01_meet_the_lizzies.scene",
    "base\\quest\\main_quests\\prologue\\q004\\scenes\\q004_02_meeting_evelyn.scene",
    "base\\quest\\main_quests\\prologue\\q004\\scenes\\q004_03_this_is_judy.scene",
    "base\\quest\\main_quests\\prologue\\q004\\scenes\\q004_04b_after_tutorial.scene",
    "base\\quest\\main_quests\\prologue\\q004\\scenes\\q004_06_see_you_later_evelyn.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_01_plan.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_01a_slice_of_afterlife.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_02_cab_ride.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_03_entrance.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_04_spiderbot.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_05_hotel_fluff.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_06_undercover.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_07_vip_apartment.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_09_attack.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_14_after_escape.scene",
    "base\\quest\\main_quests\\prologue\\q005\\scenes\\q005_15_no_tell_motel.scene",
    "base\\quest\\minor_quests\\mq000\\scenes\\mq000_01_apartment.scene",
    "base\\quest\\minor_quests\\mq000\\scenes\\mq000_03_secret_room.scene",
    "base\\quest\\minor_quests\\mq001\\scenes\\mq001_01_funeral_aftermath.scene",
    "base\\quest\\minor_quests\\mq001\\scenes\\mq001_01_mood_scenes_funeral.scene",
    "base\\quest\\minor_quests\\mq001\\scenes\\mq001_02_drive_to_cliff.scene",
    "base\\quest\\minor_quests\\mq001\\scenes\\mq001_03_cliff.scene",
    "base\\quest\\minor_quests\\mq002\\scenes\\mq002_01_deal.scene",
    "base\\quest\\minor_quests\\mq002\\scenes\\mq002_03_summary.scene",
    "base\\quest\\minor_quests\\mq003\\scenes\\mq003_01_homeless.scene",
    "base\\quest\\minor_quests\\mq003\\scenes\\mq003_03_orbital_pod.scene",
    "base\\quest\\minor_quests\\mq005\\scenes\\mq005_01_alley.scene",
    "base\\quest\\minor_quests\\mq005\\scenes\\mq005_02_passout.scene",
    "base\\quest\\minor_quests\\mq006\\scenes\\mq006_01_intro.scene",
    "base\\quest\\minor_quests\\mq006\\scenes\\mq006_02_finale.scene",
    "base\\quest\\minor_quests\\mq007\\scenes\\mq007_04_skippy_return.scene",
    "base\\quest\\minor_quests\\mq008\\scenes\\mq008_01_party_chats.scene",
    "base\\quest\\minor_quests\\mq008\\scenes\\mq008_02_shooting_contest.scene",
    "base\\quest\\minor_quests\\mq010\\scenes\\mq010_01_ncpd_door.scene",
    "base\\quest\\minor_quests\\mq010\\scenes\\mq010_02_barry_talk.scene",
    "base\\quest\\minor_quests\\mq010\\scenes\\mq010_03_columbarium.scene",
    "base\\quest\\minor_quests\\mq010\\scenes\\mq010_04_police_talk.scene",
    "base\\quest\\minor_quests\\mq010\\scenes\\mq010_05_barry_shot.scene",
    "base\\quest\\minor_quests\\mq011\\scenes\\mq011_00_gun_range.scene",
    "base\\quest\\minor_quests\\mq013\\scenes\\mq013_00_punks.scene",
    "base\\quest\\minor_quests\\mq014\\scenes\\mq014_01_hook.scene",
    "base\\quest\\minor_quests\\mq014\\scenes\\mq014_02_earth.scene",
    "base\\quest\\minor_quests\\mq014\\scenes\\mq014_03_second.scene",
    "base\\quest\\minor_quests\\mq014\\scenes\\mq014_04_water.scene",
    "base\\quest\\minor_quests\\mq014\\scenes\\mq014_05_third.scene",
    "base\\quest\\minor_quests\\mq014\\scenes\\mq014_06_fire.scene",
    "base\\quest\\minor_quests\\mq014\\scenes\\mq014_07_fourth.scene",
    "base\\quest\\minor_quests\\mq014\\scenes\\mq014_08_air.scene",
    "base\\quest\\minor_quests\\mq015\\scenes\\mq015_01_hook.scene",
    "base\\quest\\minor_quests\\mq015\\scenes\\mq015_03_restaurant.scene",
    "base\\quest\\minor_quests\\mq015\\scenes\\mq015_04_stash.scene",
    "base\\quest\\minor_quests\\mq015\\scenes\\mq015_05_afterlife.scene",
    "base\\quest\\minor_quests\\mq016\\scenes\\mq016_01_freezer.scene",
    "base\\quest\\minor_quests\\mq016\\scenes\\mq016_02_afterlife.scene",
    "base\\quest\\minor_quests\\mq017\\scenes\\mq017_streetkid_01a_johnny.scene",
    "base\\quest\\minor_quests\\mq017\\scenes\\mq017_streetkid_02_reunion.scene",
    "base\\quest\\minor_quests\\mq017\\scenes\\mq017_streetkid_03_confront_thugs.scene",
    "base\\quest\\minor_quests\\mq018\\scenes\\mq018_02_fortuneteller.scene",
    "base\\quest\\minor_quests\\mq018\\scenes\\mq018_05_brooklyn.scene",
    "base\\quest\\minor_quests\\mq018\\scenes\\mq018_06_solar.scene",
    "base\\quest\\minor_quests\\mq018\\scenes\\mq018_07_protein.scene",
    "base\\quest\\minor_quests\\mq019\\scenes\\mq019_01_notell_motel.scene",
    "base\\quest\\minor_quests\\mq019\\scenes\\mq019_03_night_club.scene",
    "base\\quest\\minor_quests\\mq019\\scenes\\mq019_04_manager.scene",
    "base\\quest\\minor_quests\\mq019\\scenes\\mq019_06_finale.scene",
    "base\\quest\\minor_quests\\mq021\\scenes\\mq021_01_briefing.scene",
    "base\\quest\\minor_quests\\mq021\\scenes\\mq021_02_hospital_meeting.scene",
    "base\\quest\\minor_quests\\mq021\\scenes\\mq021_03_ending.scene",
    "base\\quest\\minor_quests\\mq022\\scenes\\mq022_01_diner.scene",
    "base\\quest\\minor_quests\\mq023\\scenes\\mq023_01_johnny.scene",
    "base\\quest\\minor_quests\\mq023\\scenes\\mq023_02_dinner.scene",
    "base\\quest\\minor_quests\\mq023\\scenes\\mq023_03_street_vendor.scene",
    "base\\quest\\minor_quests\\mq024\\scenes\\mq024_02_meet_sandra.scene",
    "base\\quest\\minor_quests\\mq025\\scenes\\mq025_02_kabuki_new.scene",
    "base\\quest\\minor_quests\\mq025\\scenes\\mq025_03_arroyo.scene",
    "base\\quest\\minor_quests\\mq025\\scenes\\mq025_05_glen.scene",
    "base\\quest\\minor_quests\\mq025\\scenes\\mq025_06_pacifica.scene",
    "base\\quest\\minor_quests\\mq025\\scenes\\mq025_07_fight_club.scene",
    "base\\quest\\minor_quests\\mq025\\scenes\\mq025_08_finale.scene",
    "base\\quest\\minor_quests\\mq026\\scenes\\mq026_01_prophecy.scene",
    "base\\quest\\minor_quests\\mq026\\scenes\\mq026_02_death.scene",
    "base\\quest\\minor_quests\\mq026\\scenes\\mq026_03_nomad.scene",
    "base\\quest\\minor_quests\\mq026\\scenes\\mq026_04_smuggler.scene",
    "base\\quest\\minor_quests\\mq028\\scenes\\mq028_01_holocall.scene",
    "base\\quest\\minor_quests\\mq028\\scenes\\mq028_02_park.scene",
    "base\\quest\\minor_quests\\mq028\\scenes\\mq028_03_resolution.scene",
    "base\\quest\\minor_quests\\mq028\\scenes\\mq028_04_idle.scene",
    "base\\quest\\minor_quests\\mq029\\scenes\\mq029_01_james.scene",
    "base\\quest\\minor_quests\\mq030\\scenes\\mq030_01_melisa.scene",
    "base\\quest\\minor_quests\\mq032\\scenes\\mq032_01_hook.scene",
    "base\\quest\\minor_quests\\mq032\\scenes\\mq032_02_maelstrom.scene",
    "base\\quest\\minor_quests\\mq033\\scenes\\mq033_1_first_grafitti.scene",
    "base\\quest\\minor_quests\\mq033\\scenes\\mq033_2_all_grafitti.scene",
    "base\\quest\\minor_quests\\mq033\\scenes\\mq033_ep1_grafitti.scene",
    "base\\quest\\minor_quests\\mq035\\scenes\\mq035_ozob_dialogues.scene",
    "base\\quest\\minor_quests\\mq036\\scenes\\mq036_scavengers.scene",
    "base\\quest\\minor_quests\\mq036\\scenes\\mq036_stefan_dialogues.scene",
    "base\\quest\\minor_quests\\mq037\\scenes\\mq037_01_brendan_scenes.scene",
    "base\\quest\\minor_quests\\mq038\\scenes\\mq038_01_briefing.scene",
    "base\\quest\\minor_quests\\mq038\\scenes\\mq038_02_ending.scene",
    "base\\quest\\minor_quests\\mq040\\scenes\\mq040_01_bar.scene",
    "base\\quest\\minor_quests\\mq040\\scenes\\mq040_02_trail_wife.scene",
    "base\\quest\\minor_quests\\mq040\\scenes\\mq040_03_ripperdoc.scene",
    "base\\quest\\minor_quests\\mq041\\scenes\\mq041_corpo_02_confrontation.scene",
    "base\\quest\\minor_quests\\mq042\\scenes\\mq042_nomad_02_car_found.scene",
    "base\\quest\\minor_quests\\mq049\\scenes\\mq049_braindance.scene",
    "base\\quest\\minor_quests\\mq055\\scenes\\mq055_01_megabuilding.scene",
    "base\\quest\\minor_quests\\mq055\\scenes\\mq055_02_northside.scene",
    "base\\quest\\minor_quests\\mq055\\scenes\\mq055_03_japantown.scene",
    "base\\quest\\minor_quests\\mq055\\scenes\\mq055_04_heywood.scene",
    "base\\quest\\minor_quests\\mq055\\scenes\\mq055_05_downtown.scene",
    "base\\quest\\minor_quests\\mq056\\scenes\\mq056_01_city_race.scene",
    "base\\quest\\minor_quests\\mq056\\scenes\\mq056_02_badlands.scene",
    "base\\quest\\minor_quests\\mq056\\scenes\\mq056_03_santo_domingo.scene",
    "base\\quest\\minor_quests\\mq056\\scenes\\mq056_04_big_race.scene",
    "base\\quest\\minor_quests\\mq057\\scenes\\mq057_chase.scene",
    "base\\quest\\minor_quests\\mq058\\scenes\\mq058_scene_test.scene",
    "base\\quest\\minor_quests\\mq059\\scenes\\mq059_play_vos.scene",
    "base\\quest\\minor_quests\\mq060\\scenes\\mq060_android.scene",
    "base\\quest\\minor_quests\\mq060\\scenes\\mq060_connecttoterminal.scene",
    "base\\quest\\minor_quests\\mq060\\scenes\\mq060_identify.scene",
    "base\\quest\\primary_characters\\default_dialogues\\johnny_default.scene",
    "base\\quest\\primary_characters\\default_dialogues\\panam_default.scene",
    "base\\quest\\primary_characters\\default_dialogues\\sobchak_default.scene",
    "base\\quest\\secondary_characters\\default_dialogues\\jackie_default.scene",
    "base\\quest\\secondary_characters\\default_dialogues\\judy_default.scene",
    "base\\quest\\secondary_characters\\default_dialogues\\rogue_default.scene",
    "base\\quest\\secondary_characters\\default_dialogues\\saul_default.scene",
    "base\\quest\\side_quests\\sq004\\scenes\\sq004_02_intro.scene",
    "base\\quest\\side_quests\\sq004\\scenes\\sq004_04_drive.scene",
    "base\\quest\\side_quests\\sq004\\scenes\\sq004_06_prison_escape.scene",
    "base\\quest\\side_quests\\sq004\\scenes\\sq004_07_chase.scene",
    "base\\quest\\side_quests\\sq004\\scenes\\sq004_08_farm.scene",
    "base\\quest\\side_quests\\sq004\\scenes\\sq004_09_morning_after.scene",
    "base\\quest\\side_quests\\sq006\\scenes\\sq006_01a_apartment_welcome.scene",
    "base\\quest\\side_quests\\sq006\\scenes\\sq006_02a_tour.scene",
    "base\\quest\\side_quests\\sq006\\scenes\\sq006_02b_investigation.scene",
    "base\\quest\\side_quests\\sq006\\scenes\\sq006_02c_conclusion.scene",
    "base\\quest\\side_quests\\sq006\\scenes\\sq006_04a_secret_lab.scene",
    "base\\quest\\side_quests\\sq006\\scenes\\sq006_06a_clandestine.scene",
    "base\\quest\\side_quests\\sq006\\scenes\\sq006_07a_final_choice.scene",
    "base\\quest\\side_quests\\sq011\\scenes\\sq011_00_intro.scene",
    "base\\quest\\side_quests\\sq011\\scenes\\sq011_01_kerry_mansion.scene",
    "base\\quest\\side_quests\\sq011\\scenes\\sq011_02_totentanz.scene",
    "base\\quest\\side_quests\\sq011\\scenes\\sq011_07a_royce.scene",
    "base\\quest\\side_quests\\sq011\\scenes\\sq011_07b_thugs.scene",
    "base\\quest\\side_quests\\sq011\\scenes\\sq011_08_nancy_saved.scene",
    "base\\quest\\side_quests\\sq011\\scenes\\sq011_08b_denny_henry.scene",
    "base\\quest\\side_quests\\sq011\\scenes\\sq011_10_concert.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_01a_peralez_car.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_02a_braindance.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_03a_av_pad.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_04a_meet_river.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_05a_sex_shop.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_05b_market_interview.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_06a_rqr_ext.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_06b_rqr_investigation.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_07a_conclusions.scene",
    "base\\quest\\side_quests\\sq012\\scenes\\sq012_08a_peralez_apartment.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_02_coffee_cart.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_03_freeway_drive.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_04_highwaymen.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_05_car_chase.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_06_capitan_caliente.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_08_club_outside.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_09_club_inside.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_10_us_crack_intro.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_17_pachinko.scene",
    "base\\quest\\side_quests\\sq017\\scenes\\sq017_18_premiere.scene",
    "base\\quest\\side_quests\\sq018\\scenes\\sq018_00_mama_welles_holocall.scene",
    "base\\quest\\side_quests\\sq018\\scenes\\sq018_01_mama_welles.scene",
    "base\\quest\\side_quests\\sq018\\scenes\\sq018_02_storage.scene",
    "base\\quest\\side_quests\\sq018\\scenes\\sq018_03_funeral.scene",
    "base\\quest\\side_quests\\sq018\\scenes\\sq018_03a_misty.scene",
    "base\\quest\\side_quests\\sq018\\scenes\\sq018_03b_victor.scene",
    "base\\quest\\side_quests\\sq018\\scenes\\sq018_03c_padre.scene",
    "base\\quest\\side_quests\\sq018\\scenes\\sq018_03d_barman.scene",
    "base\\quest\\side_quests\\sq018\\scenes\\sq018_04b_valentinos_el_coyote.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_01_hook.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_02_ride.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_03_trailer_park.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_04_randys_room.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_04b_randys_pc.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_05_bbq.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_07_ride_back.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_09_bd_school.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_10_bd_farm.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_11_finale.scene",
    "base\\quest\\side_quests\\sq021\\scenes\\sq021_13_wrong_farm.scene",
    "base\\quest\\side_quests\\sq023\\scenes\\sq023_01_hook.scene",
    "base\\quest\\side_quests\\sq023\\scenes\\sq023_02_ride_gloria.scene",
    "base\\quest\\side_quests\\sq023\\scenes\\sq023_03_call.scene",
    "base\\quest\\side_quests\\sq023\\scenes\\sq023_04_glorias_house.scene",
    "base\\quest\\side_quests\\sq023\\scenes\\sq023_07_restaurant.scene",
    "base\\quest\\side_quests\\sq023\\scenes\\sq023_10_bd_studio.scene",
    "base\\quest\\side_quests\\sq023\\scenes\\sq023_11_01a_after_chase.scene",
    "base\\quest\\side_quests\\sq023\\scenes\\sq023_11_protesters_chats.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_01a_claire_garage.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_01b_claire_afterlife.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_02_santo_domingo_race.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_02b_santo_domingo_race_end.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_03_badlands_race.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_03b_badlands_race_end.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_04_city_race.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_04b_docks_scene.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_05_big_race.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_05b_trauma_team.scene",
    "base\\quest\\side_quests\\sq024\\scenes\\sq024_06_bar_ending.scene",
    "base\\quest\\side_quests\\sq025\\scenes\\sq025_03_reception.scene",
    "base\\quest\\side_quests\\sq025\\scenes\\sq025_05_scan.scene",
    "base\\quest\\side_quests\\sq025\\scenes\\sq025_09_labyrinth.scene",
    "base\\quest\\side_quests\\sq025\\scenes\\sq025_10_resolution.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_00_holocall_judy.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_01a_suicide.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_01b_roof.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_02_holocall_judy.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_04_maiko.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_05a_leave.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_07_judys.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_08_plan.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_09_holocall_judy.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_10_meetup.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_11_to_penthouse.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_13_hiromi.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_13a_dolls.scene",
    "base\\quest\\side_quests\\sq026\\scenes\\sq026_15_end.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_02_camp_mood_scenes.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_02_panam_and_santiago.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_03_panams_plan.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_03_saul_whistleblowing.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_03a_chats_to_locomotive.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_04_preparations_carol.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_04_preparations_cassidy_teddy.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_04_preparations_mitch_bob.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_04_preparations_panam.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_04a_camping.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_05_ambush.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_05a_transport_delivered.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_06_panzer.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_08_camp_saved.scene",
    "base\\quest\\side_quests\\sq027\\scenes\\sq027_09_new_camp_wakeup.scene",
    "base\\quest\\side_quests\\sq028\\scenes\\kerry_villa\\sq028_kerry_villa_sit.scene",
    "base\\quest\\side_quests\\sq028\\scenes\\sq028_02_welcome_aboard.scene",
    "base\\quest\\side_quests\\sq028\\scenes\\sq028_03_chilling_out.scene",
    "base\\quest\\side_quests\\sq028\\scenes\\sq028_04_destructive_tendencies.scene",
    "base\\quest\\side_quests\\sq028\\scenes\\sq028_05_sex.scene",
    "base\\quest\\side_quests\\sq028\\scenes\\sq028_06_wrap_up.scene",
    "base\\quest\\side_quests\\sq028\\scenes\\sq028_07_trashy_beach.scene",
    "base\\quest\\side_quests\\sq029\\scenes\\sq029_02a_arrival.scene",
    "base\\quest\\side_quests\\sq029\\scenes\\sq029_03_argame.scene",
    "base\\quest\\side_quests\\sq029\\scenes\\sq029_04a_dinner.scene",
    "base\\quest\\side_quests\\sq029\\scenes\\sq029_05_morning_after.scene",
    "base\\quest\\side_quests\\sq029\\scenes\\sq029_06a_sex.scene",
    "base\\quest\\side_quests\\sq030\\scenes\\sq030_00_holocall.scene",
    "base\\quest\\side_quests\\sq030\\scenes\\sq030_01_dam_meetup.scene",
    "base\\quest\\side_quests\\sq030\\scenes\\sq030_03_dam_equipment.scene",
    "base\\quest\\side_quests\\sq030\\scenes\\sq030_04_lake_dive_start.scene",
    "base\\quest\\side_quests\\sq030\\scenes\\sq030_05_lake_test.scene",
    "base\\quest\\side_quests\\sq030\\scenes\\sq030_06_lake_exploration.scene",
    "base\\quest\\side_quests\\sq030\\scenes\\sq030_09_pier.scene",
    "base\\quest\\side_quests\\sq030\\scenes\\sq030_11_morning.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_00_johnny.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_01a_smack_afterlife.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_01b_smack_tatto.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_01c_smack_striptease.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_01d_smack_rogue.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_02b_rogue_afterlife.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_03_ebunike.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_04_grayson.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_05_grave.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_07_cinema.scene",
    "base\\quest\\side_quests\\sq031\\scenes\\sq031_08_movie.scene",
    "base\\quest\\side_quests\\sq032\\scenes\\sq032_03_third_episode.scene",
    "base\\quest\\side_quests\\sq032\\scenes\\sq032_04_fourth_episode.scene",
    "base\\quest\\side_quests\\sq032\\scenes\\sq032_05_fifth_episode.scene",
    "base\\quest\\side_quests\\sq032\\scenes\\sq032_06_sixth_episode.scene",
    "base\\quest\\side_quests\\sq032\\scenes\\sq032_07_finale.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\claire_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\joss_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\kerry_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\mama_welles_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\misty_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\mitch_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\nix_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\placide_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\victor_vector_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\voodoo_queen_default.scene",
    "base\\quest\\tertiary_characters\\default_dialogues\\yawen_packard_default.scene",
    "ep1\\media\\growl\\scenes\\ep1_growl_stand.scene",
    "ep1\\media\\impulse\\scenes\\impulse.scene",
    "ep1\\openworld\\fixers\\mr_hands\\scenes\\mr_hands_combat_zone_default.scene",
    "ep1\\openworld\\mini_world_stories\\combat_zone\\mws_cz_02\\scenes\\mws_cz_02_scene_01.scene",
    "ep1\\openworld\\mini_world_stories\\combat_zone\\mws_cz_04\\scene\\mws_cz_04.scene",
    "ep1\\openworld\\mini_world_stories\\combat_zone\\mws_cz_14\\scenes\\mws_cz_14_robot_interactions.scene",
    "ep1\\openworld\\mini_world_stories\\combat_zone\\mws_cz_15\\scenes\\mws_cz_15_best_dressed_device.scene",
    "ep1\\openworld\\sandbox_activities\\courier_spot\\introduction_quest\\scene\\sa_ep1_introduction_scene_muamar.scene",
    "ep1\\openworld\\sandbox_activities\\courier_spot\\outro_quest\\outro_dock\\scenes\\daniels_ambush\\sa_ep1_courier_outro_daniels_ambush.scene",
    "ep1\\openworld\\sandbox_activities\\courier_spot\\outro_quest\\outro_dock\\scenes\\muammar_end\\sa_ep1_courier_outro_end.scene",
    "ep1\\openworld\\sandbox_activities\\courier_spot\\outro_quest\\outro_dock\\scenes\\muammar_start_dam_meetup\\sa_ep1_courier_outro_muammar_dam.scene",
    "ep1\\openworld\\sandbox_activities\\cyberjunkies\\cbj_ep1_01\\cbj_ep1_01_psycho.scene",
    "ep1\\openworld\\scene\\dancefloors\\dancefloor_ganger_party.scene",
    "ep1\\openworld\\scene\\dancefloors\\dancefloor_heavy_hearts.scene",
    "ep1\\openworld\\scene\\dancefloors\\dancefloor_rave_party.scene",
    "ep1\\openworld\\scene\\dancefloors\\dancefloor_rave_party_ctz_01.scene",
    "ep1\\openworld\\scene\\dancefloors\\ganger_party\\dancefloor_container_zone_de_12.scene",
    "ep1\\openworld\\scene\\dancefloors\\ganger_party\\dancefloor_high_peak_de_02.scene",
    "ep1\\openworld\\scene\\dancefloors\\ganger_party\\dancefloor_high_peak_de_06.scene",
    "ep1\\openworld\\scene\\dancefloors\\ganger_party\\dancefloor_high_peak_de_12.scene",
    "ep1\\openworld\\scene\\dancefloors\\ganger_party\\dancefloor_high_peak_de_13.scene",
    "ep1\\openworld\\scene\\dancefloors\\ganger_party\\dancefloor_high_peak_de_13_02.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_01\\scenes\\sts_ep1_01_anderson_saved.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_01\\scenes\\sts_ep1_01_final.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_01\\scenes\\sts_ep1_01_nika_alive.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_01\\scenes\\sts_ep1_01_odel.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_03\\scenes\\sts_ep1_03_mourner.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_03\\scenes\\sts_ep1_03_wagner_standoff.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_04\\scenes\\sts_ep1_04_hasan.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_04\\scenes\\sts_ep1_04_hasan_final.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_06_zembinsky\\scenes\\sts_ep1_06_client.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_06_zembinsky\\scenes\\sts_ep1_06_drug_dealer.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_06_zembinsky\\scenes\\sts_ep1_06_george.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_06_zembinsky\\scenes\\sts_ep1_06_interrogation.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_06_zembinsky\\scenes\\sts_ep1_06_johnny.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_06_zembinsky\\scenes\\sts_ep1_06_scavs.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_06_zembinsky\\scenes\\sts_ep1_06_violent_guy.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_06_zembinsky\\scenes\\sts_ep1_06_waitress.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_07\\scenes\\sts_ep1_07_bomb_interaction.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_07\\scenes\\sts_ep1_07_client_meeting.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_07\\scenes\\sts_ep1_07_final_meeting.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_08\\scenes\\sts_ep1_08_client_ending.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_08\\scenes\\sts_ep1_08_client_meeting.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_08\\scenes\\sts_ep1_08_target_meeting.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_10\\scenes\\sts_ep1_10_dodger_garage_scene.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_10\\scenes\\sts_ep1_10_informer.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_10\\scenes\\sts_ep1_10_interrogation_room_scene.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_10\\scenes\\sts_ep1_10_tv_crew_follow.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_12\\scenes\\sts_ep1_12_courier_scene.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_12\\scenes\\sts_ep1_12_droid_den.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_12\\scenes\\sts_ep1_12_final_scene.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_13\\scenes\\sts_ep1_13_children.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_13\\scenes\\sts_ep1_13_dolls.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_13\\scenes\\sts_ep1_13_fiona.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_13\\scenes\\sts_ep1_13_informer_deal.scene",
    "ep1\\openworld\\street_stories\\sts_ep1_13\\scenes\\sts_ep1_13_v_auction.scene",
    "ep1\\openworld\\vendors\\container_zone\\cz_con_clothingshop_01\\cz_con_clothingshop_01.scene",
    "ep1\\openworld\\vendors\\container_zone\\cz_con_foodshop_01\\cz_con_foodshop_01.scene",
    "ep1\\openworld\\vendors\\container_zone\\cz_con_gunsmith_01\\cz_con_gunsmith_01.scene",
    "ep1\\openworld\\vendors\\container_zone\\cz_con_junkshop_01\\cz_con_junkshop_01.scene",
    "ep1\\openworld\\vendors\\container_zone\\cz_con_medicstore_01\\cz_con_medicstore_01.scene",
    "ep1\\openworld\\vendors\\container_zone\\cz_con_ripdoc_01\\cz_con_ripdoc_01.scene",
    "ep1\\openworld\\vendors\\cz_foodshop_01\\cz_foodshop_01.scene",
    "ep1\\openworld\\vendors\\monument_av\\cz_monument_av_medical_odel\\cz_monument_av_medical_odel.scene",
    "ep1\\openworld\\vendors\\monument_av\\cz_monument_av_ripperdoc_anderson\\cz_monument_av_ripperdoc_anderson.scene",
    "ep1\\openworld\\vendors\\monument_av\\cz_monument_av_ripperdoc_farida\\cz_monument_av_ripperdoc_farida.scene",
    "ep1\\openworld\\vendors\\spaceport\\nw4_spaceport_medicstore_01\\nw4_spaceport_medicstore_01.scene",
    "ep1\\openworld\\vendors\\stadium\\cz_stadium_black_market_01\\cz_stadium_black_market_01.scene",
    "ep1\\openworld\\vendors\\stadium\\cz_stadium_clothing_01\\cz_stadium_clothing_01.scene",
    "ep1\\openworld\\vendors\\stadium\\cz_stadium_food_03\\cz_stadium_food_03.scene",
    "ep1\\openworld\\vendors\\stadium\\cz_stadium_gunsmith_01\\cz_stadium_gunsmith_01.scene",
    "ep1\\openworld\\vendors\\stadium\\cz_stadium_junk_01\\cz_stadium_junk_01.scene",
    "ep1\\openworld\\vendors\\stadium\\cz_stadium_medic_01\\cz_stadium_medic_01.scene",
    "ep1\\openworld\\vendors\\stadium\\cz_stadium_netrunner_01\\cz_stadium_netrunner_01.scene",
    "ep1\\openworld\\vendors\\stadium\\cz_stadium_ripperdoc_01\\cz_stadium_ripperdoc_01.scene",
    "ep1\\openworld\\world_encounters\\we_ep1_01\\scenes\\we_ep1_01_chats.scene",
    "ep1\\openworld\\world_stories\\wst_ep1_08\\wst_ep1_08_scene.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_00_holocall_hook.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_01_border.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_02a_stadium.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_02b_stadium_gameplay.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_03_crash.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_04_way_to_crashsite.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_05a_crashsite.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_06a_shuttle_arrival.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_06c_shuttle_escape.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_07_shuttle_myers.scene",
    "ep1\\quest\\main_quests\\q301\\scenes\\q301_08_escape_pod.scene",
    "ep1\\quest\\main_quests\\q302\\scenes\\q302_01_escape_the_cz.scene",
    "ep1\\quest\\main_quests\\q302\\scenes\\q302_02_spider.scene",
    "ep1\\quest\\main_quests\\q302\\scenes\\q302_03_subway.scene",
    "ep1\\quest\\main_quests\\q302\\scenes\\q302_04_squot.scene",
    "ep1\\quest\\main_quests\\q302\\scenes\\q302_05_bar.scene",
    "ep1\\quest\\main_quests\\q302\\scenes\\q302_06_basketball.scene",
    "ep1\\quest\\main_quests\\q302\\scenes\\q302_06a_ride.scene",
    "ep1\\quest\\main_quests\\q302\\scenes\\q302_07_oath.scene",
    "ep1\\quest\\main_quests\\q302\\scenes\\q302_08_call.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_02_nighthawks.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_03_voodoo_boys.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_03a_voodoo_baron.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_04_mr_hands.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_05_safehouse.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_06_paradise.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_06a_paradise_roleplay_restaurant_floor.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_06b_paradise_technical.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_06b_paradise_technical_gameplay.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_07_finale.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_08_reed_conversation.scene",
    "ep1\\quest\\main_quests\\q303\\scenes\\q303_10_concert_braindance.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_01_briefing.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_02_songbird_calls.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_02b_car_rental.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_02c_car_rental_kids.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_03_songbird_meeting.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_04_entering_stadium.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_04d_shard_pickup.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_04e_alex_heart_to_heart.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_05_garage.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_06_disguise.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_07_deal.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_07b_lab.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_08a_reed_wake_up.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_08b_songbird_wake_up.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_09a_reed_escape.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_09b_songbird_escape.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_09c_songbird_escape_combat.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_alex_grave.scene",
    "ep1\\quest\\main_quests\\q304\\scenes\\q304_car_retrieval_purge_data.scene",
    "ep1\\quest\\main_quests\\q304\\test\\q304_replacer_test.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_02b_nix.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_02d_chang.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_02e_sandra.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_04_pre_ambush_meeting.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_04a_waiting_pre_ambush.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_05_ambush_scenes.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_06_chase_scenes.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_06b_bunker_intro.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_07_brain_hack.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_08_outer_bunker_scenes.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_08c_outer_bunker_hallucination_kurt.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_08d_outer_bunker_hallucination_upgrade.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_08f_outer_bunker_minor_hallucinations.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_08g_outer_bunker_cerberus_intro.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_08h_outer_bunker_killroom.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_09a_inner_bunker_hallucination_oath.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_09b_inner_bunker_hallucination_flatline.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_09c_inner_bunker_minor_hallucinations.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_09d_cerberus_finale.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_09e_inner_bunker_lab_scenes.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_09f_inner_bunker_killroom.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_10_songbird_finale.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_11_border_crossing.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_12_johnny.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_13_reed_epilogue.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_13a_reed_waiting.scene",
    "ep1\\quest\\main_quests\\q305\\scenes\\q305_15_chang_after_quest.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_01_ride_to_spaceport.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_02_terminal_recon.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_03_terminal_mood.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_03b_oa_staff_reactions.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_04_meeting_contact.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_06_myers_intro.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_06a_blackops_intro.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_07_somi_duty_free.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_08_control_tower.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_09_monorail.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_10_finale.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_11_resolution.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_12a_mission_aftermath.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_13_epilogue.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_13b_epilogue_reed.scene",
    "ep1\\quest\\main_quests\\q306\\scenes\\q306_tv_bit.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\final_boards\\q307_ending_01_rogue.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\final_boards\\q307_ending_02_takemura.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\final_boards\\q307_ending_03_mitch.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\final_boards\\q307_ending_04_reed.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\final_boards\\q307_ending_05_viktor.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_01_pickup.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_02_coma.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_03_hospital.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_03a_friends_holocall.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_04_cabride.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_05_alley.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_06_viktor.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_07_thugs.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_08_misty.scene",
    "ep1\\quest\\main_quests\\q307\\scenes\\q307_09_cutscene.scene",
    "ep1\\quest\\minor_quests\\mq300\\scenes\\mq300_safehouse_interactions.scene",
    "ep1\\quest\\minor_quests\\mq301\\scenes\\mq301_01_fireplace.scene",
    "ep1\\quest\\minor_quests\\mq301\\scenes\\mq301_02_initiation.scene",
    "ep1\\quest\\minor_quests\\mq301\\scenes\\mq301_03_delivery.scene",
    "ep1\\quest\\minor_quests\\mq301\\scenes\\mq301_04_frame.scene",
    "ep1\\quest\\minor_quests\\mq301\\scenes\\mq301_05_run.scene",
    "ep1\\quest\\minor_quests\\mq301\\scenes\\mq301_06_contacts.scene",
    "ep1\\quest\\minor_quests\\mq303\\scenes\\mq303_01_hook.scene",
    "ep1\\quest\\minor_quests\\mq303\\scenes\\mq303_02_linas_mansion.scene",
    "ep1\\quest\\minor_quests\\mq303\\scenes\\mq303_03_finale.scene",
    "ep1\\quest\\minor_quests\\mq303\\scenes\\mq303_04_bdprincess.scene",
    "ep1\\quest\\minor_quests\\mq303\\scenes\\mq303_06_vendor.scene",
    "ep1\\quest\\minor_quests\\mq304\\scenes\\mq304_00_city_scenes.scene",
    "ep1\\quest\\minor_quests\\mq304\\scenes\\mq304_01_hook.scene",
    "ep1\\quest\\minor_quests\\mq304\\scenes\\mq304_02_hands_briefing.scene",
    "ep1\\quest\\minor_quests\\mq304\\scenes\\mq304_03_jago.scene",
    "ep1\\quest\\minor_quests\\mq304\\scenes\\mq304_03a_vdb_meeting.scene",
    "ep1\\quest\\minor_quests\\mq304\\scenes\\mq304_05_bennett.scene",
    "ep1\\quest\\minor_quests\\mq304\\scenes\\mq304_06_kurts_wake.scene",
    "ep1\\quest\\minor_quests\\mq304\\scenes\\mq304_06a_meet_bodyguards.scene",
    "ep1\\quest\\minor_quests\\mq304\\scenes\\mq304_06b_lobby.scene",
    "ep1\\quest\\minor_quests\\mq305\\scenes\\mq305_02_apartment_dante.scene",
    "ep1\\quest\\minor_quests\\mq305\\scenes\\mq305_03_apartment_johnny.scene",
    "ep1\\quest\\minor_quests\\mq305\\scenes\\mq305_04_bunker.scene",
    "ep1\\quest\\minor_quests\\mq305\\scenes\\mq305_04a_video_recordings.scene",
    "ep1\\quest\\minor_quests\\mq305\\scenes\\mq305_04b_lab_exploration.scene",
    "ep1\\quest\\minor_quests\\mq305\\scenes\\mq305_05_outcome_mr_hands.scene",
    "ep1\\quest\\minor_quests\\mq306\\scenes\\mq306_01_intro.scene",
    "ep1\\quest\\minor_quests\\mq306\\scenes\\mq306_02_tech_expo_exploration.scene",
    "ep1\\quest\\minor_quests\\mq306\\scenes\\mq306_03_expo_ripper.scene",
    "ep1\\quest\\minor_quests\\mq306\\scenes\\mq306_04a_aaron_meeting.scene",
    "ep1\\quest\\minor_quests\\mq306\\scenes\\mq306_04b_angie_meeting.scene",
    "ep1\\quest\\primary_characters\\default_dialogs\\myers_default_dialog\\president_myers_default_dialog.scene",
    "ep1\\quest\\tertiary_characters\\default_dialogs\\bill_default\\sts_10_bill_default.scene",
    "ep1\\quest\\tertiary_characters\\default_dialogs\\hana_default\\sts_03_hana_default.scene",
    "ep1\\quest\\tertiary_characters\\default_dialogs\\hasan_default\\sts_04_hasan_default.scene",
    "ep1\\quest\\tertiary_characters\\default_dialogs\\michael_maldonado_default\\michael_maldonado_default.scene",
    "ep1\\quest\\tertiary_characters\\default_dialogs\\nika_default\\sts_01_nika_default.scene",
    "ep1\\quest\\tertiary_characters\\default_dialogs\\steven_santos_default\\sts_08_steven_default_new_biomonitor_not_destroyed.scene",
    "ep1\\quest\\tertiary_characters\\default_dialogs\\steven_santos_default\\sts_08_steven_default_stadium.scene"
];

main();
