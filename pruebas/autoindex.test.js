/*
 * Pruebas de las funciones puras del listado. Se corren con `bun test pruebas/autoindex.test.js`
 * (no necesitan navegador). El archivo exporta `module.exports` con el objeto `api`.
 */
import { describe, expect, test } from "bun:test";
import * as api from "../autoindex/autoindex.js";

describe("autoindex: formatBytes", () => {
  test("bytes", () => expect(api.formatBytes(0)).toBe("0 B"));
  test("kilobytes", () => expect(api.formatBytes(1024)).toBe("1 kB"));
  test("megabytes", () => expect(api.formatBytes(1024 * 1024)).toBe("1 MB"));
  test("gigabytes", () => expect(api.formatBytes(1024 * 1024 * 1024)).toBe("1 GB"));
  test("decimales cuando < 10", () => expect(api.formatBytes(1536)).toBe("1.5 kB"));
  test("números no válidos", () => {
    expect(api.formatBytes(-1)).toBe("—");
    expect(api.formatBytes(NaN)).toBe("—");
    expect(api.formatBytes(Infinity)).toBe("—");
    expect(api.formatBytes("mucho")).toBe("—");
  });
});

describe("autoindex: formatDate", () => {
  test("fecha válida ISO", () => {
    // Mediodía local evita cambio de día por zona horaria
    const d = api.formatDate(new Date(2026, 10, 26, 12).toISOString());
    expect(d.includes("26 nov 2026") || d.includes("26 Nov 2026")).toBe(true);
  });
  test("fecha inválida", () => expect(api.formatDate("no")).toBe("—"));
  test("vacío", () => expect(api.formatDate("")).toBe("—"));
});

describe("autoindex: parsePackageName", () => {
  test("paquete x86_64", () => {
    const p = api.parsePackageName("polkit-vasak-agent-0.8.10-1-x86_64.pkg.tar.zst");
    expect(p.name).toBe("polkit-vasak-agent");
    expect(p.version).toBe("0.8.10-1");
    expect(p.arch).toBe("x86_64");
  });
  test("paquete any", () => {
    const p = api.parsePackageName("apparmor.d-0.4916.0-1-any.pkg.tar.zst");
    expect(p.name).toBe("apparmor.d");
    expect(p.version).toBe("0.4916.0-1");
    expect(p.arch).toBe("any");
  });
  test("nombre desconocido", () => {
    const p = api.parsePackageName("archivo-cualquiera.txt");
    expect(p.name).toBe("archivo-cualquiera.txt");
    expect(p.version).toBe("");
    expect(p.arch).toBe("");
  });
});

describe("autoindex: buildCrumbs", () => {
  test("raíz", () => {
    const c = api.buildCrumbs("/");
    expect(c.length).toBe(1);
    expect(c[0].label).toBe("repositorio");
  });
  test("carpeta simple", () => {
    const c = api.buildCrumbs("/repo/");
    expect(c.length).toBe(2);
    expect(c[1].label).toBe("repo");
    expect(c[1].href).toBe("/repo/");
  });
  test("ruta profunda", () => {
    const c = api.buildCrumbs("/repo/x86_64/vasakos/");
    expect(c.length).toBe(4);
    expect(c[3].label).toBe("vasakos");
    expect(c[3].href).toBe("/repo/x86_64/vasakos/");
  });
});

describe("autoindex: organise", () => {
  const entries = [
    { name: "../", type: "directory", mtime: "2026-11-26T15:00:00Z", size: 0 },
    { name: "sub/", type: "directory", mtime: "2026-11-25T10:00:00Z", size: 0 },
    { name: "pkg-1.0-1-x86_64.pkg.tar.zst", type: "file", mtime: "2026-11-26T12:00:00Z", size: 102400 },
    { name: "pkg-1.0-1-x86_64.pkg.tar.zst.sig", type: "file", mtime: "2026-11-26T12:00:00Z", size: 119 },
    { name: "vasakos.db", type: "file", mtime: "2026-11-26T13:00:00Z", size: 250000 },
    { name: "vasakos.json", type: "file", mtime: "2026-11-26T13:00:00Z", size: 5000 },
    { name: "archivo.txt", type: "file", mtime: "2026-11-26T14:00:00Z", size: 100 },
  ];

  test("sin índice, usa parsePackageName", () => {
    const o = api.organise(entries, null);
    expect(o.folders.length).toBe(1);
    expect(o.folders[0].name).toBe("sub/");
    // 3 files: 1 paquete, 1 índice (vasakos.db), 1 archivo regular
    expect(o.files.length).toBe(3);
    const pkg = o.files.find(f => f.kind === "paquete");
    expect(pkg).toBeDefined();
    expect(pkg.label).toBe("pkg");
    expect(pkg.version).toBe("1.0-1");
    expect(pkg.arch).toBe("x86_64");
    const idx = o.files.find(f => f.kind === "índice");
    expect(idx).toBeDefined();
    const reg = o.files.find(f => f.kind === "archivo");
    expect(reg).toBeDefined();
  });

  test("con índice, usa versión y descripción del json", () => {
    const index = {
      packages: [
        { name: "polkit-vasak-agent", version: "0.8.10-1", arch: "x86_64", desc: "Agente de autenticación", filename: "pkg-1.0-1-x86_64.pkg.tar.zst" }
      ]
    };
    const o = api.organise(entries, index);
    const pkg = o.files.find(f => f.kind === "paquete");
    expect(pkg).toBeDefined();
    expect(pkg.label).toBe("polkit-vasak-agent");
    expect(pkg.version).toBe("0.8.10-1");
    expect(pkg.arch).toBe("x86_64");
    expect(pkg.detail).toBe("Agente de autenticación");
  });

  test("no muestra ../ ni .sig ni vasakos.json", () => {
    const o = api.organise(entries, null);
    const names = o.files.map(f => f.name).concat(o.folders.map(f => f.name));
    expect(names.includes("../")).toBe(false);
    expect(names.includes("pkg-1.0-1-x86_64.pkg.tar.zst.sig")).toBe(false);
    expect(names.includes("vasakos.json")).toBe(false);
  });
});

describe("autoindex: normalise", () => {
  test("quita acentos", () => expect(api.normalise("versión")).toBe("version"));
  test("minúsculas", () => expect(api.normalise("POLKIT")).toBe("polkit"));
  test("vacío", () => expect(api.normalise("")).toBe(""));
});

describe("autoindex: matches", () => {
  const entry = {
    name: "pkg-1.0-1-x86_64.pkg.tar.zst",
    label: "polkit-vasak-agent",
    kind: "paquete",
    version: "0.8.10-1",
    detail: "Agente de autenticación PolicyKit",
  };
  test("vacío coincide", () => expect(api.matches(entry, "")).toBe(true));
  test("coincide en nombre de archivo", () => expect(api.matches(entry, "pkg")).toBe(true));
  test("coincide en label", () => expect(api.matches(entry, "polkit")).toBe(true));
  test("coincide en versión", () => expect(api.matches(entry, "0.8")).toBe(true));
  test("coincide en descripción", () => expect(api.matches(entry, "policykit")).toBe(true));
  test("no coincide", () => expect(api.matches(entry, "nada")).toBe(false));
});