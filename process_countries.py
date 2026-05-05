import sys

data = """1	Albania	AL
2	Algeria	DZ
3	American Samoa	AS
4	Angola	AO
5	Anguilla	AI
6	Antarctica	AQ
7	Antigua and Barbuda	AG
8	Argentina	AR
9	Aruba	AW
10	Australia	AU
11	Austria	AT
13	Bahamas	BS
14	Bahrain	BH
15	Bangladesh	BD
16	Barbados	BB
17	Belgium	BE
18	Belize	BZ
19	Benin	BJ
20	Bermuda	BM
21	Bonaire	BQ
22	Bosnia and Herzegovina	BA
23	Botswana	BW
24	Brazil	BR
25	British Virgin Islands	VG
26	Brunei Darussalam	BN
27	Bulgaria	BG
28	Cambodia	KH
29	Cameroon	CM
30	Canada	CA
31	Cape Verde	CV
32	Cayman Islands	KY
33	Côte d'Ivoire	CI
34	Chile	CL
35	China	CN
36	Colombia	CO
37	Comoros	KM
38	Cook Islands	CK
39	Costa Rica	CR
40	Croatia	HR
41	Cuba	CU
42	Curaçao	CW
43	Cyprus	CY
44	Czech Republic	CZ
45	Denmark	DK
46	Djibouti	DJ
47	Dominica	DM
48	Dominican Republic	DO
49	Ecuador	EC
50	Egypt	EG
51	El Salvador	SV
52	England	GB
53	Estonia	EE
54	Falkland Islands	FK
55	Faroe Islands	FO
56	Fiji	FJ
57	Finland	FI
58	France	FR
59	French Guiana	GF
60	French Polynesia	PF
61	Gambia	GM
62	Georgia	GE
63	Germany	DE
64	Ghana	GH
65	Gibraltar	GI
66	Greece	GR
67	Greenland	GL
68	Grenada	GD
69	Guadeloupe	GP
70	Guam	GU
71	Guatemala	GT
72	Guernsey	GG
73	Guinea-Bissau	GW
74	Haiti	HT
75	Honduras	HN
76	Hong Kong	HK
77	Hungary	HU
78	Iceland	IS
79	India	IN
80	Indonesia	ID
81	Ireland	IE
82	Isle of Man	IM
83	Israel	IL
84	Italy	IT
85	Jamaica	JM
86	Japan	JP
87	Jersey	JE
88	Jordan	JO
89	Kenya	KE
90	Kiribati	KI
91	Latvia	LV
92	Liberia	LR
93	Lithuania	LT
94	Luxembourg	LU
95	Madagascar	MG
96	Malaysia	MY
97	Maldives	MV
98	Malta	MT
99	Marshall Islands	MH
100	Martinique	MQ
101	Mauritius	MU
102	Mayotte	YT
103	Mexico	MX
104	Micronesia	FM
105	Monaco	MC
106	Montenegro	ME
107	Montserrat	MS
108	Morocco	MA
109	Mozambique	MZ
110	Myanmar	MM
111	Namibia	NA
112	Netherlands	NL
113	New Caledonia	NC
114	New Zealand	NZ
115	Nicaragua	NI
116	Niue	NU
117	Norfolk Island	NF
118	Northern Ireland	GB
119	Northern Mariana Islands	MP
120	Norway	NO
121	Oman	OM
122	Panama	PA
123	Papua New Guinea	PG
124	Peru	PE
125	Philippines	PH
126	Pitcairn	PN
127	Poland	PL
128	Portugal	PT
129	Puerto Rico	PR
130	Qatar	QA
131	Réunion	RE
132	Romania	RO
133	Russia	RU
134	Saint Barthélemy	BL
135	Saint Helenians	SH
136	Saint Kitts and Nevis	KN
137	Saint Lucia	LC
138	Saint Martin (French part)	MF
139	Saint Pierre and Miquelon	PM
140	Saint Vincent and the Grenadines	VC
141	Samoa	WS
142	Sao Tome and Principe	ST
143	Scattered Islands	TF
144	Scotland	GB
145	Senegal	SN
146	Serbia	RS
147	Seychelles	SC
148	Sierra Leone	SL
149	Singapore	SG
150	Sint Maarten (Dutch part)	SX
151	Slovakia	SK
152	Slovenia	SI
153	Solomon Islands	SB
154	South Africa	ZA
155	South Georgia and the South Sandwich Islands	GS
156	South Korea	KR
157	South Orkney Islands	AQ
158	South Shetland Islands	AQ
159	Spain	ES
160	Sri Lanka	LK
161	Suriname	SR
162	Svalbard and Jan Mayen	SJ
163	Sweden	SE
164	Switzerland	CH
165	Taiwan	TW
166	Tanzania	TZ
167	Thailand	TH
168	Timor-Leste	TL
169	Togo	TG
170	Tonga	TO
171	Trinidad and Tobago	TT
172	Tunisia	TN
173	Turkey	TR
174	Turks and Caicos Islands	TC
175	U.S. Virgin Islands	VI
176	Ukraine	UA
177	United Arab Emirates	AE
178	United States	US
179	Uruguay	UY
180	Vanuatu	VU
181	Venezuela	VE
182	Vietnam	VN
183	Wales	GB
184	Wallis and Futuna	WF
185	Western Sahara	EH
186	Zimbabwe	ZW
187	Saudi Arabia	SA
188	Palau	PW
189	Nigeria	NG
190	Equatorial Guinea	GQ
191	Tuvalu	TV
192	Laos	LA
193	Guyana	GY
194	Moldova	MD
195	Syria	SY
196	Libya	LY
197	Kuwait	KW
198	United Kingdom	GB
199	Yemen	YE"""

lines = data.split('\n')
mapping = {}
for line in lines:
    if line.strip():
        parts = line.split('\t')
        if len(parts) == 3:
            name = parts[1].replace('"', '\\"')
            code = parts[2]
            # Preference to main names instead of subdivisions
            if code in mapping and name in ["England", "Northern Ireland", "Scotland", "Wales", "South Orkney Islands", "South Shetland Islands"]:
                continue
            mapping[code] = name

print("local countryMap = {")
for code, name in sorted(mapping.items()):
    print(f'  ["{code}"] = "{name}",')
print("}")
