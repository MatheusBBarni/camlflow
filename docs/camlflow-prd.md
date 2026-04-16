# Product Requirements Document: CamlFlow (Agent Orchestration DSL)

## 1. Product Overview

**CamlFlow** is a statically-typed, functional domain-specific language (DSL) designed to orchestrate LLM agents, skills, and Model Context Protocol (MCP) tools.

Currently, agentic workflows are often orchestrated using natural language prompts, which are inherently non-deterministic, flaky, and difficult to test. CamlFlow solves this by providing a programmatic, strongly-typed execution graph. It allows developers to define inputs, instantiate custom LLM agents on the fly, bind external tools, and sequence them logically. If a required context is missing, or a step is skipped, the language catches it at "compile-time" rather than failing mid-execution.

## 2. Core Philosophy

1. **Unopinionated & Generic:** The language provides the primitives (types, bindings, pipelines). It does *not* assume specific workflows. Users bring their own tools, define their own agents, and bind them to strict signatures.
2. **Immutable Context:** Contexts and documents are immutable. An agent takes a document and returns a *new* document or package. Data flows strictly forward.
3. **Monadic Execution (`let*`):** Agent inference, human-in-the-loop interventions, and MCP tool usage take time or block execution. We use the `let*` syntax (similar to OCaml's Lwt) to represent asynchronous or blocking operations gracefully.
4. **Separation of Concerns:** Core types represent pure data. For instance, a `code_package` is just code. If a user wants to write a commit message for it, they pass it to a dedicated `commit_writer` skill rather than tying git logic to the programmer agent.

---

## 3. Language Design & Primitives

### 3.1 Custom Types and Records

Users can define their own Algebraic Data Types (ADTs) and Records to strictly enforce what an agent expects as input and what it must output.

```ocaml
(* Algebraic Data Types for heterogeneous inputs *)
type input_source =
  | PRD of file
  | Figma of url
  | Jira of string
  | TaskDesc of string

(* Strictly typed data records *)
type code_package = {
  files: file list;
  technical_decisions: string list;
  dependencies: string list;
}
```

### 3.2 Agents: Binding vs. Defining

Users have two ways to bring agents into their workflow: binding to an existing system agent, or defining a brand new agent inline.

**1. Binding Existing Agents & Skills**
For tools, MCP endpoints, or standard workspace agents that already exist in the environment.

```ocaml
(* Binding an existing workspace AI Agent *)
agent programmer : cmd:string -> reqs:req_document -> figma:(string option) -> code_package = 
  Agent.bind "the-engineer"

(* Binding deterministic skills or MCP tools *)
skill git_commit : files:(file list) -> msg:string -> commit_result =
  Skill.bind "system-git-commit"
```

**2. Defining Custom Agents Inline**
If a user doesn't have a pre-defined agent, they can use `Agent.define` to instantiate an LLM agent on the fly. The language compiler will use the return type signature to automatically enforce structured outputs (e.g., forcing the LLM to reply in a JSON schema matching the return type).

```ocaml
(* Defining a brand new agent directly in the script *)
agent security_reviewer : code:code_package -> security_report =
  Agent.define
    ~model:"gemini-3.1-pro"
    ~temperature:0.1
    ~system_prompt:"You are a strict DevSecOps engineer. Review the provided code package for OWASP vulnerabilities. Return the findings in the required format."
```

---

## 4. Reference Implementation: The Dev-Pipeline

Below is the implementation of a full development pipeline. It demonstrates merging inputs, binding existing skills, defining a custom agent inline, and sequential context passing.

### The Pipeline Script (`dev_pipeline.cml`)

```ocaml
(* ========================================== *)
(* 1. TYPE DEFINITIONS                        *)
(* ========================================== *)

type input_source =
  | PRD of file
  | Figma of url
  | Jira of string
  | TaskDesc of string

type raw_context = {
  prd_data: string option;
  figma_data: string option;
  jira_data: string option;
  task_data: string option;
}

type req_document = { ... }
type code_package = { files: file list; ... }
type test_package = { files: file list; coverage: string; }
type review_report = { approved: bool; blockers: string list; suggestions: string list; }

(* ========================================== *)
(* 2. AGENTS & SKILLS                         *)
(* ========================================== *)

(* Bind external skills *)
skill grill_me : raw_context -> req_document = Skill.bind "grill-me"
skill commit_writer : diff:(file list) -> reqs:req_document -> string = Skill.bind "commit-writer"
skill git_commit : files:(file list) -> msg:string -> commit_result = Skill.bind "git-commit"

(* Bind an existing, heavy-duty programmer agent *)
agent programmer : cmd:string -> reqs:req_document -> figma:(string option) -> code_package = 
  Agent.bind "the-engineer"

(* Define custom, lightweight agents inline *)
agent qa_engineer : reqs:req_document -> code:code_package -> test_package = 
  Agent.define
    ~model:"gemini-3.1-pro"
    ~system_prompt:"You are a QA Engineer. Write comprehensive unit tests for the provided code."

agent code_reviewer : reqs:req_document -> code:code_package -> tests:test_package -> jira:(string option) -> review_report = 
  Agent.define
    ~model:"gemini-3.1-pro"
    ~temperature:0.2
    ~system_prompt:"Review code and tests against the requirements. Fail the review if tests do not cover all edge cases."

(* ========================================== *)
(* 3. PIPELINE ORCHESTRATION                  *)
(* ========================================== *)

(** Step 0: Input Collection & Merging **)
let collect_inputs (inputs: input_source list) : raw_context =
  if List.length inputs = 0 then
    failwith "Pipeline requires at least one input source."
  else
    (* Fetch logic here... *)
    { prd_data = None; figma_data = None; jira_data = None; task_data = None }

(** The Main Orchestration Flow **)
let dev_pipeline (inputs: input_source list) =
  (* Step 0: Parse and merge inputs *)
  let raw_ctx = collect_inputs inputs in

  (* Step 1: grill-me (Blocking operation, waits for user to answer questions) *)
  let* req_doc = grill_me raw_ctx in

  (* Step 2: Programmer Agent *)
  let* code_pkg = programmer ~cmd:"/caveman" ~reqs:req_doc ~figma:raw_ctx.figma_data in

  (* Step 2.5: Dynamic Commit Message & Git Commit *)
  let* commit_msg = commit_writer ~diff:code_pkg.files ~reqs:req_doc in
  let* _commit_code = git_commit ~files:code_pkg.files ~msg:commit_msg in

  (* Step 3: Custom QA Agent (Defined inline) *)
  let* test_pkg = qa_engineer ~reqs:req_doc ~code:code_pkg in

  (* Step 3.5: Dynamic Test Commit *)
  let* test_commit_msg = commit_writer ~diff:test_pkg.files ~reqs:req_doc in
  let* _commit_tests = git_commit ~files:test_pkg.files ~msg:test_commit_msg in

  (* Step 4: Custom Reviewer Agent (Defined inline) *)
  let* review = 
    code_reviewer 
      ~reqs:req_doc 
      ~code:code_pkg 
      ~tests:test_pkg 
      ~jira:raw_ctx.jira_data 
  in

  (* Final Output *)
  Report.generate 
    ~title:"✅ Pipeline Complete"
    ~inputs_used:inputs 
    ~review:review
```

---

## 5. Execution Engine Requirements

For the CamlFlow interpreter/runtime to function, it must support the following underlying mechanisms:

### 5.1 Monadic Suspension (Human & AI in the Loop)

When the runtime evaluates `let* req_doc = grill_me raw_ctx`, the execution state is suspended. If `grill-me` requires human input (via chat UI), the execution graph pauses indefinitely until the UI returns the required `req_document` payload.

### 5.2 Dynamic Agent Instantiation & Structured Output

When the runtime encounters an `Agent.define` block, it must seamlessly interface with the specified LLM provider's API. Crucially, the compiler must map the CamlFlow return type (e.g., `review_report`) to the LLM's `response_schema` or `structured_output` parameters, guaranteeing that the dynamically created agent strictly adheres to the workflow's data types.

### 5.3 Strict Context Passing

The compiler must enforce lexical scoping. It must be impossible to invoke `qa_engineer` without passing `code_pkg`. This structurally prevents "skipping steps" and guarantees that the AI agents always receive complete, properly formatted contexts, dramatically reducing hallucinations.

### 5.4 Extensible Binding Layer (MCP & External Tools)

The `Skill.bind` keywords must map to an underlying registry (e.g., an MCP server, a local Python script, or a REST API). The language runtime acts purely as the traffic controller, marshaling the strongly-typed records into JSON for the external tool, and validating the returned JSON back into the CamlFlow types.

