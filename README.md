# Zava Agentic E-Commerce Demo

Demo showcasing **Azure HorizonDB** AI capabilities (AI Pipelines, hybrid search,
DiskANN vector search, graph queries) through a "Zava Designer Agent" e-commerce
scenario — an agentic room-design assistant that searches a product catalog,
reasons over a knowledge graph, and renders furnished rooms.

## Structure

- `demo-sql/` — SQL scripts for AI Pipelines ingestion, hybrid AI Search, and graph creation, plus a full demo script (`DEMO_PLAN.md`).
- `zava-designer-agent-ui-demo/` — React + Express UI for the interactive designer agent demo.

## Setup

1. Copy the env templates and fill in your own Azure OpenAI / HorizonDB credentials:
   ```bash
   cp .env.example .env
   cp zava-designer-agent-ui-demo/.env.example zava-designer-agent-ui-demo/.env
   ```
2. Install UI dependencies:
   ```bash
   cd zava-designer-agent-ui-demo
   npm install
   ```

## Dataset

The full demo uses the public **Amazon Reviews 2023 — Home & Kitchen** metadata
dataset (~100K products, ~7.7GB as `Home_and_Kitchen.jsonl.gz`), which is not
included in this repo due to size. Download it from the
[Amazon Reviews 2023 dataset](https://amazon-reviews-2023.github.io/) and place
it at the repo root, or use `demo-sql/setup/sample_data_products.csv` for a
smaller sample to get started quickly.
