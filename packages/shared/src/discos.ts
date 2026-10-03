/** VTpass electricity serviceIDs (each verified on its VTpass doc page, docs/RESEARCH.md Q19).
 *  Live min/max amounts come from GET /services?identifier=electricity-bill at runtime. */
export const DISCOS = [
  { serviceID: "ikeja-electric", short: "IKEDC", name: "Ikeja Electric", region: "Lagos (Ikeja)" },
  { serviceID: "eko-electric", short: "EKEDC", name: "Eko Electric", region: "Lagos (Eko)" },
  { serviceID: "abuja-electric", short: "AEDC", name: "Abuja Electric", region: "FCT, Niger, Kogi, Nasarawa" },
  { serviceID: "kano-electric", short: "KEDCO", name: "Kano Electric", region: "Kano, Jigawa, Katsina" },
  { serviceID: "portharcourt-electric", short: "PHED", name: "Port Harcourt Electric", region: "Rivers, Bayelsa, Cross River, Akwa Ibom" },
  { serviceID: "jos-electric", short: "JED", name: "Jos Electric", region: "Plateau, Bauchi, Benue, Gombe" },
  { serviceID: "kaduna-electric", short: "KAEDCO", name: "Kaduna Electric", region: "Kaduna, Kebbi, Sokoto, Zamfara" },
  { serviceID: "enugu-electric", short: "EEDC", name: "Enugu Electric", region: "Enugu, Abia, Anambra, Ebonyi, Imo" },
  { serviceID: "ibadan-electric", short: "IBEDC", name: "Ibadan Electric", region: "Oyo, Ogun, Osun, Kwara" },
  { serviceID: "benin-electric", short: "BEDC", name: "Benin Electric", region: "Edo, Delta, Ondo, Ekiti" },
  { serviceID: "aba-electric", short: "Aba Power", name: "Aba Power", region: "Aba (Abia)" },
  { serviceID: "yola-electric", short: "YEDC", name: "Yola Electric", region: "Adamawa, Taraba, Borno, Yobe" },
] as const;

export type ServiceID = (typeof DISCOS)[number]["serviceID"];
export const SERVICE_IDS = DISCOS.map((d) => d.serviceID) as unknown as readonly [ServiceID, ...ServiceID[]];
export const discoByServiceId = (id: string) => DISCOS.find((d) => d.serviceID === id);
