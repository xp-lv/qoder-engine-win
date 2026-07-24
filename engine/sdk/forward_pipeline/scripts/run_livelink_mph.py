"""跑 SDK solve_forward on livelink_model.mph + 空心球 CSV。"""
import sys
import io
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

PROJECT_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(PROJECT_ROOT))

from engine.sdk.forward_pipeline import ForwardPipeline


def main():
    pipe = ForwardPipeline(
        comsol_server_path=r"D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe",
        mli_path=r"D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli",
        matlab_exe=r"D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe",
        comsol_port=2036,
        cache_root=str(PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/.cache"),
        startup_timeout=240,
        run_timeout=900,
    )

    work = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/livelink_run"
    work.mkdir(parents=True, exist_ok=True)

    result = pipe.solve_forward(
        eps_real_csv=str(PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/hollow_sphere_eps.csv"),
        eps_imag_csv="",
        freq_list=[1e9],
        model_path=str(PROJECT_ROOT / "COMSOL/livelink_model.mph"),
        output_dir=str(work),
        n_directions=64,
        measurement_R=0.26,
        run_v5a=False,
        use_cache=False,
    )

    print()
    print("=" * 60)
    print("RESULT")
    print("=" * 60)
    print(f"status:       {result.status}")
    print(f"stage:        {result.stage}")
    err = result.error_msg or "(none)"
    if len(err) > 400:
        err = err[:400] + "..."
    print(f"error_msg:    {err}")
    print(f"mat_path:     {result.mat_path}")
    print(f"json_path:    {result.json_path}")
    print(f"v5a_verdict:  {result.v5a_verdict}")
    print(f"duration_sec: {result.duration_sec:.1f}")

    if result.status == "success":
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
