-- Starting catalogue. Prices stay null until Kyindu's price list is in; set them in the POS (Products tab).
insert into public.products (id, name, category, unit, img, description, contains, sort) values
('family','Family pack','packs','pack','img/chuck.webp','A week of meals for four.','["1 kg mince","1 kg stewing beef","1 kg rump steak"]',1),
('braai-pack','Braai pack','packs','pack','img/ribeye.webp','Everything for a weekend braai for six to eight.','["1 kg T-bone","1 kg boerewors","1 kg short ribs","0.5 kg rump steak"]',2),
('freezer','Monthly freezer box','packs','pack','img/topside.webp','A month of beef for a family, packed by cut.','["3 kg mince","3 kg stewing beef","2 kg rump steak","1 kg T-bone","1 kg boerewors"]',3),
('rump','Rump steak','steaks','kg','img/rump.webp','Lean and full of flavour. Grill, pan-fry or slice for stir-fry.',null,10),
('sirloin','Sirloin','steaks','kg','img/striploin.webp','The classic steak, with a strip of fat for flavour.',null,11),
('tbone','T-bone','steaks','kg',null,'Sirloin and fillet on the bone. Made for the braai.',null,12),
('fillet','Fillet','steaks','kg','img/tenderloin.webp','The most tender cut. Whole or cut into medallions.',null,13),
('mince','Mince','everyday','kg',null,'Freshly minced. For bolognese, burgers and samosas.',null,20),
('stew','Stewing beef','everyday','kg','img/chuck.webp','Bone-in pieces for stews and relish with nshima.',null,21),
('brisket','Brisket','slow','kg','img/brisket.webp','Slow-cook, braise or smoke until it pulls apart.',null,30),
('shin','Shin','slow','kg','img/shin.webp','Rich and gelatinous. Best for soups and long stews.',null,31),
('topside','Topside roast','slow','kg','img/topside.webp','A lean roasting joint. Also good for biltong.',null,32),
('wors','Boerewors','braai','kg',null,'Fresh beef sausage, spiced the traditional way.',null,40),
('ribs','Short ribs','braai','kg','img/ribeye.webp','Meaty ribs for the braai or a slow oven.',null,41),
('liver','Liver','offal','kg',null,'Fried with onions, the way it should be.',null,50)
on conflict (id) do nothing;
