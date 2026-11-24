/** The reels' colours: the brand's slate blue, a night page for the 3D map, and amber for what matters. */
export const C = {
  slate: '#4F6F96',
  slateDeep: '#3A5678',
  night: '#141D2B',
  nightSoft: '#1E2B3F',
  mist: '#EEF2F7',
  sand: '#F4EDE1',
  moss: '#3F6B55',
  amber: '#FFB940',
  amberDeep: '#F59A1B',
  ink: '#152030',
  paper: '#FAFBFD',
  go: '#34C77B',
};

export type ThemeName = 'slate' | 'night' | 'mist' | 'sand' | 'moss';

export const THEMES: Record<ThemeName, { bg: string; bg2: string; ink: string; soft: string; line: string; mark: string; chip: string; chipInk: string }> = {
  slate: { bg: '#4F6F96', bg2: '#35506F', ink: '#F7FAFF', soft: 'rgba(240,246,255,.86)', line: 'rgba(255,255,255,.16)', mark: C.amber, chip: '#F7FAFF', chipInk: '#34506F' },
  night: { bg: '#1B2738', bg2: '#0E141F', ink: '#F4F7FC', soft: 'rgba(226,234,246,.84)', line: 'rgba(140,175,230,.16)', mark: C.amber, chip: C.amber, chipInk: '#1B2638' },
  mist: { bg: '#EEF2F7', bg2: '#D9E2EE', ink: '#152030', soft: '#4B5B6C', line: 'rgba(79,111,150,.16)', mark: '#E8890C', chip: '#4F6F96', chipInk: '#F7FAFF' },
  sand: { bg: '#F5EEE2', bg2: '#E9DCC6', ink: '#241C12', soft: '#665744', line: 'rgba(190,140,60,.20)', mark: '#D9780F', chip: '#D9822B', chipInk: '#FFF8EC' },
  moss: { bg: '#3F6B55', bg2: '#294A3A', ink: '#F5FAF4', soft: 'rgba(236,246,236,.86)', line: 'rgba(235,250,235,.16)', mark: '#FFE08A', chip: '#F5FAF4', chipInk: '#2F5642' },
};
