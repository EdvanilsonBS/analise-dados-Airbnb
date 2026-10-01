-- Criar tabelas para receber os dados csv
CREATE TABLE neighbourhoods (
    id SERIAL PRIMARY KEY,
	neighbourhood_group  TEXT,
    neighbourhood TEXT
);

-- Criar tabela listings 
CREATE TABLE listings (
    id BIGINT,
    name TEXT,
    host_id BIGINT,
    host_name TEXT,
    neighbourhood_group DOUBLE PRECISION,
    neighbourhood TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    room_type TEXT,
    price DOUBLE PRECISION,
    minimum_nights INTEGER,
    number_of_reviews INTEGER,
    last_review DATE,
    reviews_per_month DOUBLE PRECISION,
    calculated_host_listings_count INTEGER,
    availability_365 INTEGER,
    number_of_reviews_ltm INTEGER,
    license DOUBLE PRECISION
);

-- Criar tabela reviews
CREATE TABLE reviews (
    listing_id BIGINT,
    date DATE
);

-- Verificar se os dados foram carregados

SELECT * FROM public.listings
SELECT * FROM public.reviews
SELECT * FROM public.listings

-- Agora vamos trabalhar no DW para poder conseguir responder as perguntas. 
-- Criando DW 
CREATE SCHEMA dw_Airbnb;

-- Criando tabelas no DW
CREATE TABLE dw_Airbnb.dim_bairro
(
    id INT PRIMARY KEY,
    bairro VARCHAR(100) NOT NULL,
    grupo_bairro VARCHAR(100) 
);

CREATE TABLE dw_Airbnb.dim_bairro (
  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bairro TEXT NOT NULL,
  grupo_bairro TEXT
);

-- adicionar dados na tabela dim_bairro
INSERT INTO dw_Airbnb.dim_bairro (id, bairro, grupo_bairro)
SELECT ROW_NUMBER() OVER (ORDER BY neighbourhood),
       neighbourhood,
       neighbourhood_group
FROM neighbourhoods;

SELECT * FROM dw_airbnb.dim_bairro;

CREATE TABLE dw_Airbnb.dim_tipo_imovel
(
    id INT PRIMARY KEY,
    tipo_imovel VARCHAR(100) NOT NULL
);

-- adicionar dados na tabela dim_tipo_imovel
INSERT INTO dw_Airbnb.dim_tipo_imovel (id, tipo_imovel)
SELECT ROW_NUMBER() OVER (ORDER BY room_type),
       room_type
FROM (
    SELECT DISTINCT room_type
    FROM listings
    WHERE room_type IS NOT NULL
) t;

SELECT * FROM dw_Airbnb.dim_tipo_imovel;

CREATE TABLE dw_Airbnb.dim_anfitriao
(
    id INT PRIMARY KEY,
    nome VARCHAR(150) NOT NULL,
    quantidade_anuncios INT
);

-- adicionar dados na tabela dim-anfitriao
INSERT INTO dw_Airbnb.dim_anfitriao (id, nome, quantidade_anuncios)
SELECT host_id,
       COALESCE(MAX(host_name), 'Não informado'),
       COUNT(*)
FROM listings
WHERE host_id IS NOT NULL
GROUP BY host_id;

SELECT * FROM dw_Airbnb.dim_anfitriao;

CREATE TABLE dw_Airbnb.dim_tempo
(
    id INT PRIMARY KEY,
    data DATE NOT NULL,
    mes INT NOT NULL,
    nome_mes VARCHAR(20) NOT NULL,
    ano INT NOT NULL,
    estacao VARCHAR(20) NOT NULL
);

-- adicionar dados na tabela dim_tempo
INSERT INTO dw_Airbnb.dim_tempo (id, data, mes, nome_mes, ano, estacao)
SELECT DISTINCT
    to_char(r.date::date, 'YYYYMMDD')::int AS id,
    r.date::date AS data,
    EXTRACT(MONTH FROM r.date::date)::int AS mes,
    (ARRAY['Janeiro','Fevereiro','Março','Abril','Maio','Junho',
           'Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'])
           [EXTRACT(MONTH FROM r.date::date)::int] AS nome_mes,
    EXTRACT(YEAR FROM r.date::date)::int AS ano,
    CASE 
        WHEN (EXTRACT(MONTH FROM r.date::date)*100 + EXTRACT(DAY FROM r.date::date)) >= 1221 
          OR (EXTRACT(MONTH FROM r.date::date)*100 + EXTRACT(DAY FROM r.date::date)) <= 320 THEN 'Verão'
        WHEN (EXTRACT(MONTH FROM r.date::date)*100 + EXTRACT(DAY FROM r.date::date)) BETWEEN 321 AND 620 THEN 'Outono'
        WHEN (EXTRACT(MONTH FROM r.date::date)*100 + EXTRACT(DAY FROM r.date::date)) BETWEEN 621 AND 922 THEN 'Inverno'
        ELSE 'Primavera'
    END AS estacao
FROM reviews r
ON CONFLICT (id) DO NOTHING;
SELECT * FROM dw_Airbnb.dim_tempo;

--Criar tabela fato_avaliacoes
CREATE TABLE dw_Airbnb.fato_avaliacoes
(
    id INT PRIMARY KEY,
    id_bairro INT,
    id_imovel INT,
    id_anfitriao INT,
    id_tempo INT,

    FOREIGN KEY (id_bairro)
        REFERENCES dw_Airbnb.dim_bairro (id),

    FOREIGN KEY (id_imovel)
        REFERENCES dw_Airbnb.dim_tipo_imovel (id),

    FOREIGN KEY (id_anfitriao)
        REFERENCES dw_Airbnb.dim_anfitriao (id),

    FOREIGN KEY (id_tempo)
        REFERENCES dw_Airbnb.dim_tempo (id)
);

-- Inserir dados na tabala fato_avalacoes

INSERT INTO dw_Airbnb.fato_avaliacoes (id, id_bairro, id_imovel, id_anfitriao, id_tempo)
SELECT 
    ROW_NUMBER() OVER (ORDER BY r.date, r.listing_id),
    b.id,
    ti.id,
    l.host_id,
    to_char(r.date::date, 'YYYYMMDD')::int AS id_tempo
FROM reviews r
JOIN listings l ON l.id = r.listing_id
LEFT JOIN dw_Airbnb.dim_bairro b ON b.bairro = l.neighbourhood
LEFT JOIN dw_Airbnb.dim_tipo_imovel ti ON ti.tipo_imovel = l.room_type;

SELECT * FROM dw_Airbnb.fato_avaliacoes;

--Quais bairros têm poucos imóveis e alta demanda?
-- 1.Passo: Mapeamento da Oferta (oferta): Conta quantos imóveis ativos existem em cada bairro.
WITH oferta AS (
    SELECT neighbourhood AS bairro, COUNT(*) AS qtd_imoveis
    FROM listings
    GROUP BY neighbourhood
),
--2.Passo: Mapeamento da Demanda (demanda): Soma quantas avaliações os imóveis de cada bairro receberam nos últimos 12 meses (usando a avaliação como indicador direto de reserva/ocupação).
demanda AS (
    SELECT b.bairro, COUNT(*) AS avaliacoes_12m
    FROM dw_Airbnb.fato_avaliacoes f
    JOIN dw_Airbnb.dim_bairro b ON b.id = f.id_bairro
    JOIN dw_Airbnb.dim_tempo  t ON t.id = f.id_tempo
    WHERE t.data > (SELECT MAX(data) FROM dw_Airbnb.dim_tempo) - INTERVAL '12 months'
    GROUP BY b.bairro
),
-- 3.Passo: Indicador de Pressão (calculo):
--1. Filtra apenas bairros com pelo menos 10 imóveis (relevância estatística).
--2. Cria a métrica central: Avaliações por Imóvel ($\frac{\text{Avaliações}}{\text{Imóveis}}$). Se um bairro tem 100 avaliações e 10 imóveis, cada imóvel teve média de 10 reservas no ano.
calculo AS (
    SELECT o.bairro,
           o.qtd_imoveis,
           COALESCE(d.avaliacoes_12m, 0) AS avaliacoes_12m,
           COALESCE(d.avaliacoes_12m, 0)::numeric / o.qtd_imoveis AS avaliacoes_por_imovel
    FROM oferta o
    LEFT JOIN demanda d USING (bairro)
    WHERE o.qtd_imoveis >= 10
),
--4.Passo: Linha de Corte Dinâmica (medianas): Calcula a mediana da cidade para a quantidade de imóveis e para a demanda por imóvel. 
	--Usar a mediana (em vez da média) evita que bairros gigantes como Copacabana distorçam o padrão do resto da cidade.
medianas AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY qtd_imoveis)           AS med_oferta,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avaliacoes_por_imovel) AS med_demanda
    FROM calculo
)
--5.Passo: Matriz de Decisão (CASE WHEN): Compara cada bairro contra as medianas e o encaixa em 4 cenários:
SELECT c.bairro AS "Bairro",
       TRANSLATE(TO_CHAR(c.qtd_imoveis, 'FM999,999,990'), ',', '.') AS "Imóveis",
       TRANSLATE(TO_CHAR(c.avaliacoes_12m, 'FM999,999,990'), ',', '.') AS "Avaliações (12 meses)",
       TRANSLATE(TO_CHAR(c.avaliacoes_por_imovel, 'FM999,990.0'), ',.', '.,') AS "Avaliações por imóvel",
       CASE
            WHEN c.qtd_imoveis <= m.med_oferta AND c.avaliacoes_por_imovel >= m.med_demanda
                 THEN 'Poucos imóveis e alta demanda'
            WHEN c.qtd_imoveis >  m.med_oferta AND c.avaliacoes_por_imovel >= m.med_demanda
                 THEN 'Muitos imóveis e alta demanda'
            WHEN c.qtd_imoveis <= m.med_oferta
                 THEN 'Poucos imóveis e baixa demanda'
            ELSE 'Muitos imóveis e baixa demanda'
       END AS "Situação"
FROM calculo c
CROSS JOIN medianas m
ORDER BY c.avaliacoes_por_imovel DESC
LIMIT 15;

--Quais bairros concentram imóveis de alto valor?
-- 1.Passo Define a régua de luxo: top 25% mais caros da cidade (Percentil 75)
WITH corte AS (
    SELECT PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price) AS p75
    FROM listings
    WHERE price > 0
),
-- 2. Consolida as estatísticas por bairro e conta os imóveis de alto valor
calculo AS (
    SELECT l.neighbourhood AS bairro,
           COUNT(*) AS qtd_imoveis,
           AVG(l.price) AS preco_medio,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.price) AS preco_mediano,
           COUNT(*) FILTER (WHERE l.price >= c.p75) AS qtd_alto_valor
    FROM listings l
    CROSS JOIN corte c
    WHERE l.price > 0
    GROUP BY l.neighbourhood
    HAVING COUNT(*) >= 10
)
-- 3. Formata os dados para apresentação e ordena pela proporção de luxo
SELECT bairro AS "Bairro",
       TRANSLATE(TO_CHAR(qtd_imoveis, 'FM999,999,990'), ',', '.') AS "Imóveis",
       'R$ ' || TRANSLATE(TO_CHAR(preco_mediano, 'FM999,999,990.00'), ',.', '.,') AS "Preço mediano",
       'R$ ' || TRANSLATE(TO_CHAR(preco_medio, 'FM999,999,990.00'), ',.', '.,') AS "Preço médio",
       TRANSLATE(TO_CHAR(qtd_alto_valor, 'FM999,999,990'), ',', '.') AS "Quantidade Imóveis de alto valor",
       TRANSLATE(TO_CHAR(100.0 * qtd_alto_valor / qtd_imoveis, 'FM990.0'), '.', ',') || '%'  AS "pct_alto_valor %"
FROM calculo
ORDER BY (qtd_alto_valor::numeric / qtd_imoveis) DESC
LIMIT 15;

--Existe concentração geográfica de determinados tipos de imóveis?
-- 1.Passo: Agrupa e conta a quantidade de imóveis por bairro e tipo
WITH por_bairro AS (
    SELECT neighbourhood AS bairro, room_type, COUNT(*) AS qtd
    FROM listings
    GROUP BY neighbourhood, room_type
),
-- 2.Passo: Aplica Window Functions para calcular o % no bairro e o Quociente Locacional (QL)
calculo AS (
    SELECT bairro,
           room_type,
           qtd,
           100.0 * qtd / SUM(qtd) OVER (PARTITION BY bairro) AS pct_no_bairro,
           (qtd::numeric / SUM(qtd) OVER (PARTITION BY bairro)) /
           (SUM(qtd) OVER (PARTITION BY room_type)::numeric / SUM(qtd) OVER ()) AS ql
    FROM por_bairro
)
-- 3.Passo: Traduz os termos, formata números e classifica a intensidade da concentração 
SELECT bairro AS "Bairro",
       CASE room_type
            WHEN 'Entire home/apt' THEN 'Casa/apartamento inteiro'
            WHEN 'Private room'    THEN 'Quarto privativo'
            WHEN 'Shared room'     THEN 'Quarto compartilhado'
            WHEN 'Hotel room'      THEN 'Quarto de hotel'
            ELSE room_type
       END AS "Tipo de imóvel",
       TRANSLATE(TO_CHAR(qtd, 'FM999,999,990'), ',', '.') AS "Imóveis",
       TRANSLATE(TO_CHAR(pct_no_bairro, 'FM990.0'), '.', ',') || '%' AS "% no bairro",
       TRANSLATE(TO_CHAR(ql, 'FM990.00'), '.', ',') AS "Quociente locacional",
       CASE WHEN ql >= 1.5 THEN 'Forte concentração'
            WHEN ql >= 1.0 THEN 'Acima da média'
            ELSE 'Abaixo da média' END AS "Situação"
FROM calculo
WHERE qtd >= 10
ORDER BY ql DESC
LIMIT 15;

--Quais regiões apresentam oportunidade de expansão?
-- 1. Agrupa oferta e preço mediano por bairro
WITH oferta AS (
    SELECT neighbourhood AS bairro,
           COUNT(*) AS qtd_imoveis,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price) AS preco_mediano
    FROM listings
    WHERE price > 0
    GROUP BY neighbourhood
    HAVING COUNT(*) >= 10
),
-- 2. Soma as avaliações dos últimos 12 meses
demanda AS (
    SELECT b.bairro, COUNT(*) AS avaliacoes_12m
    FROM dw_Airbnb.fato_avaliacoes f
    JOIN dw_Airbnb.dim_bairro b ON b.id = f.id_bairro
    JOIN dw_Airbnb.dim_tempo  t ON t.id = f.id_tempo
    WHERE t.data > (SELECT MAX(data) FROM dw_Airbnb.dim_tempo) - INTERVAL '12 months'
    GROUP BY b.bairro
),
-- 3. Consolida e calcula o indicador de pressão de demanda
base AS (
    SELECT o.bairro,
           o.qtd_imoveis,
           o.preco_mediano,
           COALESCE(d.avaliacoes_12m, 0)::numeric / o.qtd_imoveis AS avaliacoes_por_imovel
    FROM oferta o
    LEFT JOIN demanda d USING (bairro)
),
-- 4. Normaliza as variáveis em percentis (0 a 1) e calcula a Nota Média
calculo AS (
    SELECT bairro, qtd_imoveis, preco_mediano, avaliacoes_por_imovel,
           (PERCENT_RANK() OVER (ORDER BY avaliacoes_por_imovel)
          + (1 - PERCENT_RANK() OVER (ORDER BY qtd_imoveis))
          + PERCENT_RANK() OVER (ORDER BY preco_mediano))::numeric / 3 AS nota
    FROM base
)
-- 5. Apresenta o ranking final formatado e classificado por prioridade
SELECT bairro AS "Bairro",
       TRANSLATE(TO_CHAR(qtd_imoveis, 'FM999,999,990'), ',', '.') AS "Imóveis",
       TRANSLATE(TO_CHAR(avaliacoes_por_imovel, 'FM999,990.0'), ',.', '.,') AS "Avaliações por imóvel",
       'R$ ' || TRANSLATE(TO_CHAR(preco_mediano, 'FM999,999,990.00'), ',.', '.,') AS "Preço mediano",
       TRANSLATE(TO_CHAR(nota, 'FM0.00'), '.', ',') AS "Nota (0 a 1)",
       CASE WHEN nota >= 0.75 THEN 'Alta '
            WHEN nota >= 0.50 THEN 'Média'
            ELSE 'Baixa' END  AS "Prioridade"
FROM calculo
ORDER BY nota DESC
LIMIT 15;

