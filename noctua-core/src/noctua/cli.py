from __future__ import annotations

from pathlib import Path

import typer
from kubernetes import client, config
from kubernetes.client.rest import ApiException
from rich.console import Console
from rich.markdown import Markdown

from noctua.analyst.rules import RuleBasedAnalyst
from noctua.collectors.events import EventsCollector
from noctua.collectors.logs import LogsCollector
from noctua.collectors.pod_status import PodStatusCollector
from noctua.collectors.rollout import RolloutCollector
from noctua.models.bundle import EvidenceBundle
from noctua.report import render_markdown

app = typer.Typer(name="noctua", help="Evidence-first incident investigation for Kubernetes.")
console = Console()


@app.command()
def investigate(
    target: str = typer.Argument(..., help="<namespace>/<pod> or just <pod>"),
    namespace: str = typer.Option("default", "--namespace", "-n", help="Kubernetes namespace"),
    output: Path | None = typer.Option(None, "--output", "-o", help="Write report to file"),
    json_out: bool = typer.Option(False, "--json", help="Write bundle JSON alongside the report"),
) -> None:
    """Collect evidence from a pod, rank hypotheses, and generate a report."""
    if "/" in target:
        namespace, pod = target.split("/", 1)
    else:
        pod = target

    console.print(f"[bold cyan]Noctua[/] investigating [yellow]{namespace}/{pod}[/] …")

    try:
        config.load_kube_config()
    except Exception:
        try:
            config.load_incluster_config()
        except Exception:
            console.print("[red]ERROR:[/] No kubeconfig found and not running in-cluster.")
            raise typer.Exit(1)

    v1 = client.CoreV1Api()
    apps_v1 = client.AppsV1Api()
    bundle = EvidenceBundle(namespace=namespace, pod=pod)

    collectors = [
        PodStatusCollector(v1),
        EventsCollector(v1),
        LogsCollector(v1),
        RolloutCollector(v1, apps_v1),
    ]
    for collector in collectors:
        try:
            bundle.evidence.extend(collector.collect(namespace, pod))
        except ApiException as exc:
            console.print(f"[yellow]WARN[/] {collector.__class__.__name__}: {exc.reason}")

    bundle.seal()
    bundle = RuleBasedAnalyst().analyse(bundle)

    report = render_markdown(bundle)

    if output:
        output.write_text(report, encoding="utf-8")
        console.print(f"Report → [green]{output}[/]")
        if json_out:
            json_path = output.with_suffix(".json")
            json_path.write_text(bundle.model_dump_json(indent=2), encoding="utf-8")
            console.print(f"Bundle → [green]{json_path}[/]")
    else:
        console.print(Markdown(report))
