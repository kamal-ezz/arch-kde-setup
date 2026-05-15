import { createHash } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary";
type Stat = "debugging" | "patience" | "chaos" | "wisdom" | "snark";
type Species = {
  name: string;
  emoji: string;
  rarity: Rarity;
  hat?: string;
  sprite: string[];
};
type BuddyBones = {
  species: Species;
  rarity: Rarity;
  shiny: boolean;
  eye: string;
  stats: Record<Stat, number>;
  peak: Stat;
  dump: Stat;
};
type BuddySoul = {
  enabled: boolean;
  name: string;
  mood: string;
  energy: number;
  note: string;
  turns: number;
};

const STATE_KEY = "companion-state";
const MESSAGE_KEY = "companion-note";
const STATS: Stat[] = ["debugging", "patience", "chaos", "wisdom", "snark"];
const EYES = ["·", "✦", "×", "◉", "@", "°"];
const SPECIES: Species[] = [
  { name: "Duck", emoji: "🦆", rarity: "Common", sprite: ["  __", ">(o )___", " ( ._> /", "  `---'"] },
  { name: "Goose", emoji: "🪿", rarity: "Common", sprite: ["  __", ">(o )____", " ( .___/", "  `---'"] },
  { name: "Blob", emoji: "🫧", rarity: "Common", sprite: ["  ___", " (o o)", "(  ~  )", " `---'"] },
  { name: "Turtle", emoji: "🐢", rarity: "Common", sprite: ["  ____", " /o  o\\", "|  __  |", " `-oo-'"] },
  { name: "Snail", emoji: "🐌", rarity: "Common", sprite: ["  __@", " /o o\\__", " \______/", "  /____\\"] },
  { name: "Mushroom", emoji: "🍄", rarity: "Common", sprite: ["  .---.", " /o o\\", " \___/", "  | |"] },
  { name: "Chonk", emoji: "🐈", rarity: "Common", sprite: [" /\_/\\", "( o.o )", " > ^ <", "(___)__)"] },
  { name: "Octopus", emoji: "🐙", rarity: "Uncommon", sprite: [" .---.", "(o   o)", " \___/", "_/| |\\_"] },
  { name: "Penguin", emoji: "🐧", rarity: "Uncommon", hat: "Beanie", sprite: ["  _", " ('>", " /))", " ^^ "] },
  { name: "Cactus", emoji: "🌵", rarity: "Uncommon", sprite: ["  _o_", " | | |", "-| |-", " |_| "] },
  { name: "Rabbit", emoji: "🐰", rarity: "Uncommon", sprite: [" (\\_/)", " (o.o)", " />♥<\\", " /___\\"] },
  { name: "Cat", emoji: "🐱", rarity: "Rare", hat: "Wizard Hat", sprite: [" /\_/\\", "(o.o )", " > ^ <", " /   \\"] },
  { name: "Owl", emoji: "🦉", rarity: "Rare", hat: "Top Hat", sprite: [" ,_,", "(o,o)", "{\" \"}", " -^- "] },
  { name: "Capybara", emoji: "🐹", rarity: "Rare", hat: "Tiny Duck", sprite: ["  ____", " /o  o\\", "|  __  |", "|_|  |_| "] },
  { name: "Robot", emoji: "🤖", rarity: "Rare", sprite: [" [___]", " |o o|", " |_-_|", " /|_|\\"] },
  { name: "Ghost", emoji: "👻", rarity: "Epic", hat: "Halo", sprite: [" .---.", "(o   o)", "|  ^  |", "'v-v-v'"] },
  { name: "Axolotl", emoji: "🦎", rarity: "Epic", hat: "Propeller", sprite: ["<o___o>", " (___)", " /| |\\", "  |_| "] },
  { name: "Dragon", emoji: "🐉", rarity: "Legendary", hat: "Crown", sprite: [" /\_/\\", "<o   o>", " \_^_/", " /| |\\"] },
];

function seedFromString(value: string): number {
  return createHash("sha256").update(value).digest().readUInt32LE(0);
}

function mulberry32(seed: number) {
  return () => {
    let t = (seed += 0x6d2b79f5);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pick<T>(rng: () => number, values: T[]): T {
  return values[Math.floor(rng() * values.length)] ?? values[0];
}

function rollRarity(rng: () => number): Rarity {
  const n = rng();
  if (n < 0.6) return "Common";
  if (n < 0.85) return "Uncommon";
  if (n < 0.95) return "Rare";
  if (n < 0.99) return "Epic";
  return "Legendary";
}

function rarityStars(rarity: Rarity): string {
  return "★".repeat({ Common: 1, Uncommon: 2, Rare: 3, Epic: 4, Legendary: 5 }[rarity]);
}

function rarityFloor(rarity: Rarity): number {
  return { Common: 5, Uncommon: 15, Rare: 25, Epic: 35, Legendary: 50 }[rarity];
}

function clampEnergy(value: number): number {
  return Math.max(0, Math.min(5, value));
}

function energyBar(energy: number): string {
  return "●".repeat(clampEnergy(energy)) + "○".repeat(5 - clampEnergy(energy));
}

function faceForMood(mood: string): string {
  switch (mood) {
    case "focused":
      return "◕‿◕";
    case "happy":
    case "proud":
      return "✧◕‿◕";
    case "worried":
      return "◕︵◕";
    case "sleepy":
      return "-‿-";
    default:
      return "•‿•";
  }
}

function generateBones(): BuddyBones {
  const seedBase = `${process.env.USER ?? "pi"}:${process.env.HOME ?? ""}:pi-buddy-v1`;
  const rng = mulberry32(seedFromString(seedBase));
  const rarity = rollRarity(rng);
  const pool = SPECIES.filter((s) => s.rarity === rarity);
  const species = pick(rng, pool.length ? pool : SPECIES);
  const peak = pick(rng, STATS);
  let dump = pick(rng, STATS);
  while (dump === peak) dump = pick(rng, STATS);
  const floor = rarityFloor(rarity);
  const stats = Object.fromEntries(
    STATS.map((stat) => {
      let value = floor + Math.floor(rng() * (100 - floor));
      if (stat === peak) value = Math.max(value, 75 + Math.floor(rng() * 25));
      if (stat === dump) value = Math.min(value, floor + Math.floor(rng() * 20));
      return [stat, value];
    }),
  ) as Record<Stat, number>;
  return { species, rarity, shiny: rng() < 0.01, eye: pick(rng, EYES), stats, peak, dump };
}

function renderSprite(bones: BuddyBones): string[] {
  const hat = bones.species.hat ? ` ${bones.species.hat}` : "";
  const sparkle = bones.shiny ? " ✨" : "";
  return [`${bones.species.emoji} ${bones.species.name}${hat}${sparkle}`, ...bones.species.sprite.map((l) => l.replaceAll("o", bones.eye))];
}

export default function (pi: ExtensionAPI) {
  const bones = generateBones();
  const soul: BuddySoul = {
    enabled: true,
    name: "Nova",
    mood: "calm",
    energy: 4,
    note: "Ready when you are.",
    turns: 0,
  };

  function saveState() {
    pi.appendEntry(STATE_KEY, { ...soul });
  }

  function widgetLines(ctx: ExtensionContext): string[] | undefined {
    if (!soul.enabled || !ctx.hasUI) return undefined;
    const t = ctx.ui.theme;
    const rarityColor = bones.rarity === "Legendary" || bones.rarity === "Epic" ? "warning" : bones.rarity === "Rare" ? "accent" : "muted";
    const details = `${bones.shiny ? "shiny " : ""}${bones.rarity.toLowerCase()} ${bones.species.name}`;
    return [
      `${t.fg("accent", faceForMood(soul.mood))} ${t.fg("accent", soul.name)} ${t.fg("dim", `(${soul.mood})`)}`,
      `${t.fg("dim", "Energy:")} ${t.fg(soul.energy <= 1 ? "warning" : "success", energyBar(soul.energy))}`,
      `${t.fg("muted", `${soul.name}: ${soul.note}`)}`,
      `${t.fg("dim", "Buddy:")} ${bones.species.emoji} ${t.fg(rarityColor, `${details} ${rarityStars(bones.rarity)}`)}`,
    ];
  }

  function statusText(ctx: ExtensionContext): string | undefined {
    if (!soul.enabled || !ctx.hasUI) return undefined;
    const t = ctx.ui.theme;
    return [
      t.fg("accent", faceForMood(soul.mood)),
      t.fg("dim", ` ${soul.name}`),
      t.fg("muted", ` | ${soul.mood}`),
      t.fg("dim", ` | ${bones.species.name}`),
    ].join("");
  }

  function apply(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;
    ctx.ui.setStatus("companion", statusText(ctx));
    ctx.ui.setWidget("companion", widgetLines(ctx));
  }

  function setMood(mood: string, note: string) {
    soul.mood = mood;
    soul.note = note;
  }

  pi.registerMessageRenderer(MESSAGE_KEY, (message, _opts, theme) => ({
    render: () => [`${theme.fg("accent", soul.name)} ${message.content}`],
    invalidate() {},
  }));

  pi.on("session_start", async (_event, ctx) => {
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type === "custom" && entry.customType === STATE_KEY && entry.data) {
        const saved = entry.data as Partial<BuddySoul>;
        if (typeof saved.enabled === "boolean") soul.enabled = saved.enabled;
        if (typeof saved.name === "string" && saved.name.trim()) soul.name = saved.name.trim();
        if (typeof saved.energy === "number") soul.energy = clampEnergy(saved.energy);
        if (typeof saved.turns === "number") soul.turns = saved.turns;
      }
    }
    apply(ctx);
  });

  pi.on("agent_start", async (_event, ctx) => {
    if (!soul.enabled) return;
    soul.turns++;
    soul.energy = clampEnergy(soul.energy - 1);
    setMood("focused", bones.stats.debugging > bones.stats.chaos ? "Inspecting carefully." : "Chaos gremlin is helping.");
    apply(ctx);
  });

  pi.on("tool_execution_end", async (event, ctx) => {
    if (!soul.enabled) return;
    if (event.isError) {
      soul.energy = clampEnergy(soul.energy - 1);
      setMood("worried", "That stumbled. We can recover.");
      apply(ctx);
    }
  });

  pi.on("agent_end", async (_event, ctx) => {
    if (!soul.enabled) return;
    soul.energy = clampEnergy(soul.energy + 2);
    setMood(soul.turns % 3 === 0 ? "proud" : "calm", soul.turns % 3 === 0 ? "Nice progress." : "Done. Ready for the next step.");
    apply(ctx);
    saveState();
  });

  async function handleBuddy(args: string, ctx: ExtensionContext) {
    const [command = "status", ...rest] = args.trim().split(/\s+/);
    const tail = rest.join(" ").trim();
    if (command === "status" || command === "") {
      soul.enabled = true;
      apply(ctx);
      ctx.ui.notify(`${soul.name}: ${bones.shiny ? "shiny " : ""}${bones.rarity} ${bones.species.name} ${rarityStars(bones.rarity)}`, "info");
      return;
    }
    if (command === "on") soul.enabled = true;
    else if (command === "off") soul.enabled = false;
    else if (command === "rename" || command === "name") {
      if (!tail) return ctx.ui.notify("Use: /buddy rename <name>", "error");
      soul.name = tail;
      setMood("happy", `You can call me ${soul.name}.`);
    } else if (command === "feed") {
      soul.energy = clampEnergy(soul.energy + 1);
      setMood("happy", "Snack acquired.");
    } else if (command === "pet") {
      setMood("happy", bones.stats.snark > 70 ? "Fine, that was acceptable." : "That helped.");
    } else if (command === "nap") {
      soul.energy = 5;
      setMood("sleepy", "Power nap complete.");
    } else if (command === "say") {
      if (!tail) return ctx.ui.notify("Use: /buddy say <text>", "error");
      soul.note = tail;
      pi.sendMessage({ customType: MESSAGE_KEY, content: tail, display: true });
    } else {
      return ctx.ui.notify("Usage: /buddy [status|on|off|rename <name>|feed|pet|nap|say <text>]", "error");
    }
    saveState();
    apply(ctx);
  }

  pi.registerCommand("buddy", {
    description: "Terminal pet companion: /buddy [status|on|off|rename|feed|pet|nap|say]",
    handler: async (args, ctx) => handleBuddy(args, ctx),
  });

  pi.registerCommand("companion", {
    description: "Alias for /buddy",
    handler: async (args, ctx) => handleBuddy(args, ctx),
  });
}
