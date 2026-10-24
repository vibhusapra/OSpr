"""Actual stdio MCP local-model selection; no GUI, microphone or history."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


async def run(python):
    from mcp import Client, StdioServerParameters
    records = []
    with tempfile.TemporaryDirectory(prefix='ospr-text-choice-mcp-') as directory:
        params = StdioServerParameters(command=str(python),args=['-m','ospr_backend.mcp_server'],
                                       env=dict(os.environ,PYTHONPATH=str(ROOT/'backend'),HF_HUB_OFFLINE='1'),cwd=directory)
        async with Client(params,read_timeout_seconds=300) as client:
            listing = (await client.list_tools()).tools
            tool = next(row for row in listing if row.name == 'rewrite_text')
            assert tool.input_schema['properties']['model']['default'] == 'rewrite-quality'
            for model, repository in [('rewrite-quality','mlx-community/Qwen3-4B-Instruct-2507-4bit'),
                                      ('meeting-quality','mlx-community/Qwen3.5-9B-4bit')]:
                text = 'Please do not ship Friday.'
                result = await client.call_tool('rewrite_text',dict(text=text,instruction='Fix punctuation.',model=model))
                assert not result.is_error,result
                reply = json.loads(result.content[0].text)
                assert reply['original']==text and reply['model']==repository and reply['finish_reason']=='stop'
                records.append(dict(model=model,result=reply))
            bad = await client.call_tool('rewrite_text',dict(text='PRIVATE_SYNTHETIC_TEXT',instruction='Clean.',model='untrusted/model'))
            assert bad.is_error and 'PRIVATE_SYNTHETIC_TEXT' not in str(bad.content)
    metadata = python.parents[3]/'build-info.json'
    return dict(status='passed-local-text-choice-mcp',records=records,invalid_model_rejected_without_echo=True,
                build=json.loads(metadata.read_text()) if metadata.is_file() else None,
                boundary='Actual local stdio MCP tool schema, two cached selected-model acknowledgements and invalid-model rejection. MCP returns raw generated text with original for review; no Swift fidelity guard, UI, insertion, provider or representative quality claim.')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python',type=Path,default=Path(sys.executable))
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    result=asyncio.run(run(args.python.absolute()))
    args.output.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    print(result['status'])


if __name__=='__main__':
    main()
