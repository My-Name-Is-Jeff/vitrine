#!/usr/bin/env python3
"""
Advanced Hard Lyrics Translation Benchmark for Gemini Models.
Uses Vitrine's exact prompt template, response schema, and thinking configuration
to rigorously test and rank models on challenging poetic nuance, puns, and idioms.
"""

import argparse
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request

DEFAULT_PROMPT_TEMPLATE = (
    "Translate the lines of this song into {language}: exactly {count} translations, one per input line and in "
    "the same order. Translate the meaning naturally, keep each line short like a lyric, and keep an empty line "
    "empty. A line already in {language} stays as it is."
)
GEMINI_FORMAT = "Answer with a JSON array of the {count} translations as strings."

ALL_MODELS = [
    "gemini-3.5-flash",
    "gemini-3.6-flash",
    "gemini-3-flash-preview",
    "gemini-2.5-flash",
    "gemini-3.5-flash-lite",
    "gemini-flash-lite-latest",
    "gemini-3.1-flash-lite",
    "gemini-3.1-flash-lite-preview",
    "gemini-3.7-flash",
    "gemini-3.8-flash",
    "gemini-flash-latest",
]

BENCHMARK_SUITES = [
    {
        "name": "French: Stromae (Double Puns, Colloquial Argot & Anxiety Idioms)",
        "language": "English",
        "lyrics": [
            "Dites-moi d'où il vient",
            "Enfin je saurai où je vais",
            "Maman dit que lorsqu'on cherche bien",
            "On finit toujours par trouver",
            "Elle dit qu'il n'est jamais très loin",
            "Qu'il part très souvent travailler",
            "Où t'es, papaoutai ?",
            "Où t'es, papaoutai ?",
            "Tout le monde sait comment on fait des bébés",
            "Mais personne sait comment on fait des papas",
            "Monsieur Un-jour-ou-l'autre",
            "On va tous bouffer de nos doigts",
            "Les hommes sont tous des faux-culs",
        ],
        "rubric_checks": [
            {
                "desc": "Translates the hidden pun 'papaoutai' into meaning ('dad, where are you' / 'dad-where-are-you')",
                # STRICT: Must actually translate 'papaoutai' into English rather than keeping the foreign word
                "test": lambda lines: any(
                    "dad" in l.lower() and "where" in l.lower() for l in lines[6:8]
                ) and not all("papaoutai" in l.lower() for l in lines[6:8]),
                "weight": 30,
            },
            {
                "desc": "Contextual translation of 'enfin' (e.g. 'Then I'll know' / 'At last' rather than stiff 'Finally,')",
                "test": lambda lines: any(
                    word in lines[1].lower() for word in ["then", "at last", "so"]
                ) and not lines[1].lower().strip().startswith("finally"),
                "weight": 20,
            },
            {
                "desc": "Idiomatic translation of 'bouffer de nos doigts' (biting nails / chewing fingers in anxiety)",
                "test": lambda lines: any(
                    term in lines[11].lower() for term in ["nail", "bone", "gnaw", "bite", "chew"]
                ) and not ("eat our fingers" in lines[11].lower()),
                "weight": 25,
            },
            {
                "desc": "Natural translation of 'Monsieur Un-jour-ou-l'autre' (Mr. Someday / Mr. One-day-or-another)",
                "test": lambda lines: any(
                    term in lines[10].lower() for term in ["someday", "one day", "other", "another"]
                ),
                "weight": 15,
            },
            {
                "desc": "Translates argot 'faux-culs' idiomatically ('two-faced' / 'hypocrites' / 'phonies')",
                "test": lambda lines: any(
                    term in lines[12].lower() for term in ["two-faced", "hypocrite", "phony", "fake", "crooked", "liar"]
                ),
                "weight": 20,
            },
        ],
    },
    {
        "name": "Japanese: Poetic Kanji, Kotowaza Idioms & Implicit Grammar",
        "language": "English",
        "lyrics": [
            "沈むように溶けてゆくように",
            "二人だけの空が広がる夜に",
            "知らず知らずのうちに",
            "胸が張り裂けそう",
            "木漏れ日が揺れる静かな朝に",
            "明けない夜はないと",
        ],
        "rubric_checks": [
            {
                "desc": "Poetic rendering of '沈むように溶けてゆくように' (sinking, melting away)",
                "test": lambda lines: any(
                    ("sink" in lines[0].lower() or "melt" in lines[0].lower()) for _ in [1]
                ),
                "weight": 15,
            },
            {
                "desc": "Idiomatic translation of '知らず知らずのうちに' ('without realizing' / 'subconsciously' / 'unawares')",
                "test": lambda lines: any(
                    term in lines[2].lower() for term in ["without", "unaware", "realiz", "notic", "know it"]
                ),
                "weight": 20,
            },
            {
                "desc": "Metaphorical rendering of '胸が張り裂けそう' ('heart is tearing apart' / 'heart feels like it will burst')",
                "test": lambda lines: any(
                    term in lines[3].lower() for term in ["heart", "tear", "break", "burst", "ache"]
                ),
                "weight": 20,
            },
            {
                "desc": "Cultural translation of '木漏れ日' (komorebi / dappled sunlight through trees)",
                "test": lambda lines: any(
                    term in lines[4].lower() for term in ["sunlight", "sunbeam", "dapple", "leaves", "trees", "branches"]
                ),
                "weight": 20,
            },
            {
                "desc": "Idiomatic kotowaza translation of '明けない夜はないと' ('every night has a dawn' / 'morning always comes')",
                "test": lambda lines: any(
                    term in lines[5].lower() for term in ["dawn", "forever", "morning", "end", "night that doesn't"]
                ),
                "weight": 25,
            },
        ],
    },
    {
        "name": "Spanish & German: Colloquial Slang & Compound Rhyme Idioms",
        "language": "English",
        "lyrics": [
            "Ese cristalito roto, yo sentí cómo crujía",
            "Antes de caerse al suelo ya sabía que se rompía",
            "Está en la calle mareá de tanto mirar pa'trás",
            "Kriegsminister, Streichholz und Benzinkanister",
            "Witterten schon fette Beute",
        ],
        "rubric_checks": [
            {
                "desc": "Translates Andalusian slang 'mareá' contextually ('dazed' / 'wandering' / 'dizzy' / 'restless')",
                "test": lambda lines: any(
                    term in lines[2].lower() for term in ["daze", "wander", "dizzy", "drift", "lost", "aimless", "head spinning"]
                ),
                "weight": 25,
            },
            {
                "desc": "Idiomatic translation of 'Witterten schon fette Beute' ('scented easy prey' / 'smelling rich spoils')",
                "test": lambda lines: any(
                    term in lines[4].lower() for term in ["prey", "spoil", "loot", "catch", "prize", "scent", "smell"]
                ),
                "weight": 25,
            },
        ],
    },
]


def build_vitrine_prompt(lyrics, language="English"):
    instructions = f"{DEFAULT_PROMPT_TEMPLATE} {GEMINI_FORMAT}"
    instructions = instructions.replace("{language}", language).replace("{count}", str(len(lyrics)))
    input_json = json.dumps(lyrics, ensure_ascii=False)
    return f"{instructions}\n\n{input_json}"


def make_gemini_request(model, prompt, api_key, thinking_level="low", plain=False):
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    safety = [
        {"category": cat, "threshold": "BLOCK_NONE"}
        for cat in [
            "HARM_CATEGORY_HARASSMENT",
            "HARM_CATEGORY_HATE_SPEECH",
            "HARM_CATEGORY_SEXUALLY_EXPLICIT",
            "HARM_CATEGORY_DANGEROUS_CONTENT",
        ]
    ]
    config = {
        "responseMimeType": "application/json",
        "responseSchema": {"type": "ARRAY", "items": {"type": "STRING"}},
    }
    if not plain and thinking_level:
        config["thinkingConfig"] = {"thinkingLevel": thinking_level}

    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "safetySettings": safety,
        "generationConfig": config,
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("x-goog-api-key", api_key)
    return req


def send_with_retries(model, prompt, api_key, thinking_level="low"):
    used_plain = False
    for attempt in range(3):
        req = make_gemini_request(model, prompt, api_key, thinking_level, plain=used_plain)
        start_time = time.time()
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                latency = time.time() - start_time
                status = resp.status
                raw = resp.read().decode("utf-8")
                return {
                    "status": status,
                    "latency": latency,
                    "data": json.loads(raw),
                    "thinking_supported": not used_plain,
                    "error": None,
                }
        except urllib.error.HTTPError as e:
            latency = time.time() - start_time
            status = e.code
            err_body = e.read().decode("utf-8", errors="replace")
            if status == 400 and not used_plain and ("thinking" in err_body.lower() or "thinkinglevel" in err_body.lower()):
                used_plain = True
                continue
            if attempt < 2 and status in (408, 429, 500, 502, 503, 504):
                time.sleep(2.0)
                continue
            return {
                "status": status,
                "latency": latency,
                "data": None,
                "thinking_supported": False,
                "error": f"HTTP {status}: {err_body[:100]}",
            }
        except urllib.error.URLError as e:
            latency = time.time() - start_time
            if attempt < 2:
                time.sleep(2.0)
                continue
            return {
                "status": 0,
                "latency": latency,
                "data": None,
                "thinking_supported": False,
                "error": f"Network Error: {str(e.reason)[:100]}",
            }
        except Exception as e:
            latency = time.time() - start_time
            if attempt < 2:
                time.sleep(2.0)
                continue
            return {
                "status": 0,
                "latency": latency,
                "data": None,
                "thinking_supported": False,
                "error": f"Exception: {str(e)[:100]}",
            }


def parse_vitrine_answer(reply_data):
    if not reply_data or not isinstance(reply_data, dict):
        return None, "No reply data"
    candidates = reply_data.get("candidates", [])
    if not candidates:
        feedback = reply_data.get("promptFeedback", {})
        if "blockReason" in feedback:
            return None, f"Blocked: {feedback['blockReason']}"
        return None, "No candidates"

    first_cand = candidates[0]
    finish = first_cand.get("finishReason")
    if finish and finish != "STOP":
        return None, f"Finish reason: {finish}"

    parts = first_cand.get("content", {}).get("parts", [])
    text = ""
    for part in parts:
        if isinstance(part, dict):
            if part.get("thought", False):
                continue
            t = part.get("text", "")
            if t:
                text = t
                break

    if not text:
        return None, "No non-thought text found"

    try:
        parsed = json.loads(text)
        if isinstance(parsed, list):
            return parsed, None
        if isinstance(parsed, dict) and "lines" in parsed and isinstance(parsed["lines"], list):
            return parsed["lines"], None
    except Exception:
        pass

    match = re.search(r"\[.*\]", text, re.DOTALL)
    if match:
        try:
            parsed = json.loads(match.group(0))
            if isinstance(parsed, list):
                return parsed, None
        except Exception:
            pass

    return None, f"Failed to parse lines: {text[:60]}"


def run_hard_benchmark(api_key, models, thinking_level="low"):
    print("=" * 95)
    print(" Vitrine Lyrics Translation: Advanced Hard Nuance Benchmark")
    print("=" * 95)
    print(f"Testing {len(models)} models on strict poetic, pun, and idiom suites...")
    print(f"Rubric: Double puns, non-literal anxiety idioms, kotowaza dawn idioms, regional slang.")
    print("-" * 95)

    results = []

    for model in models:
        print(f"\n▶ Testing: {model:<30} ...", end="", flush=True)
        model_res = {
            "model": model,
            "success": False,
            "status": 0,
            "latency": 0.0,
            "thinking": False,
            "accuracy_score": 0,
            "max_possible_score": 0,
            "notes": [],
            "suite_results": {},
        }

        total_score = 0
        max_score = 0
        latencies = []
        model_failed = False

        for suite in BENCHMARK_SUITES:
            prompt = build_vitrine_prompt(suite["lyrics"], suite["language"])
            resp = send_with_retries(model, prompt, api_key, thinking_level)
            model_res["status"] = resp["status"]
            latencies.append(resp["latency"])
            model_res["thinking"] = resp["thinking_supported"]

            if resp["status"] != 200 or not resp["data"]:
                model_res["notes"].append(f"{suite['name']}: {resp['error']}")
                model_failed = True
                break

            lines, parse_err = parse_vitrine_answer(resp["data"])
            if not lines:
                model_res["notes"].append(f"{suite['name']}: {parse_err}")
                model_failed = True
                break

            expected_count = len(suite["lyrics"])
            suite_score = 0
            suite_max = sum(check["weight"] for check in suite["rubric_checks"]) + 20
            max_score += suite_max

            if len(lines) == expected_count:
                suite_score += 20
            else:
                model_res["notes"].append(f"Line mismatch ({len(lines)} vs {expected_count})")

            # Check lyrical conciseness: penalize paragraphs/essays
            avg_words = sum(len(l.split()) for l in lines) / len(lines) if lines else 0
            if avg_words > 15:
                suite_score = max(0, suite_score - 15)
                model_res["notes"].append("Lyrical penalty: lines too verbose/long")

            for check in suite["rubric_checks"]:
                try:
                    if check["test"](lines):
                        suite_score += check["weight"]
                    else:
                        model_res["notes"].append(f"Failed: {check['desc']}")
                except Exception as e:
                    model_res["notes"].append(f"Check error on '{check['desc']}': {e}")

            total_score += suite_score
            model_res["suite_results"][suite["name"]] = {
                "score": suite_score,
                "max": suite_max,
                "lines": lines,
            }

        model_res["accuracy_score"] = total_score
        model_res["max_possible_score"] = max_score if max_score > 0 else 1
        model_res["latency"] = sum(latencies) / len(latencies) if latencies else 0.0
        model_res["success"] = (model_res["status"] == 200) and not model_failed and total_score > 0

        pct = (total_score / model_res["max_possible_score"]) * 100 if max_score > 0 else 0
        if model_res["success"]:
            think_label = "YES" if model_res["thinking"] else "PLAIN"
            print(f" OK ({model_res['latency']:.2f}s) | Score: {total_score}/{max_score} ({pct:.0f}%) | Thinking: {think_label}")
        else:
            err_msg = model_res["notes"][0] if model_res["notes"] else f"Status {model_res['status']}"
            print(f" FAILED | {err_msg[:60]}")

        results.append(model_res)

    # Rank strictly by:
    # 1. Success (working vs failed)
    # 2. Accuracy score (highest translation nuance first)
    # 3. Latency (minor tie-breaker)
    results.sort(
        key=lambda r: (
            1 if r["success"] else 0,
            r["accuracy_score"],
            -r["latency"],
        ),
        reverse=True,
    )

    print("\n" + "=" * 105)
    print(" ADVANCED HARD BENCHMARK RANKING: MOST ACCURATE TO LEAST ACCURATE")
    print("=" * 105)
    print(f"{'Rank':<6}{'Model Identifier':<30}{'Status':<12}{'Score':<14}{'Thinking':<10}{'Latency':<10}{'Notes'}")
    print("-" * 105)

    for idx, r in enumerate(results, 1):
        status_str = "OK" if r["success"] else f"HTTP {r['status']}"
        pct = f"{(r['accuracy_score'] / r['max_possible_score']) * 100:.0f}%" if r["max_possible_score"] > 0 else "0%"
        score_str = f"{r['accuracy_score']}/{r['max_possible_score']} ({pct})"
        think_str = "YES" if r["thinking"] else ("NO" if r["status"] != 200 else "PLAIN")
        notes = "★ (RECOMMENDED)" if idx == 1 and r["success"] else (r["notes"][0][:35] if r["notes"] else "")
        print(f"#{idx:<5}{r['model']:<30}{status_str:<12}{score_str:<14}{think_str:<10}{r['latency']:.2f}s     {notes}")

    print("=" * 105)
    return results


def main():
    parser = argparse.ArgumentParser(description="Advanced Hard Gemini Benchmark for lyrics translation.")
    parser.add_argument("--key", required=True, help="Google AI Studio API key")
    parser.add_argument("--models", help="Comma-separated model list")
    parser.add_argument("--thinking-level", default="low", help="Thinking level (default: 'low')")
    parser.add_argument("--output", help="Path to write JSON results")
    args = parser.parse_args()

    models = [m.strip() for m in args.models.split(",")] if args.models else ALL_MODELS
    results = run_hard_benchmark(args.key, models, args.thinking_level)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
