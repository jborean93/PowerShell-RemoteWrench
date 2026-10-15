using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Text;

namespace RemoteWrench.Ext;

/// <summary>The text of a script to define in the remote session.</summary>
/// <param name="Text">The script text.</param>
/// <param name="ParamBlock">
/// The param block of the remote function that runs it, with any comment based help and attributes before it.
/// It is always an advanced function, see <see cref="ScriptParser.GetParamBlock"/>.
/// </param>
/// <param name="IsAdvanced">Whether the script itself is an advanced script.</param>
/// <param name="UsingValues">The values of its $using: expressions keyed for the -% parameter.</param>
internal sealed record ParsedScript(string Text, string ParamBlock, bool IsAdvanced, Hashtable UsingValues);

internal static class ScriptParser
{
    private sealed class UndefinedValue
    {
        public static readonly UndefinedValue Value = new();

        private UndefinedValue()
        { }
    }

    /// <summary>Parses a script to define in the remote session.</summary>
    /// <param name="scriptBlock">The script to parse.</param>
    /// <param name="usingState">
    /// The session state to get the $using: values from, or null if the script
    /// runs on the client where $using: is not supported.
    /// </param>
    /// <param name="description">What the script is, used in error messages.</param>
    /// <returns>The parsed script.</returns>
    /// <exception cref="ArgumentException">The script is invalid or a $using: variable is not set.</exception>
    public static ParsedScript Parse(ScriptBlock scriptBlock, SessionState? usingState, string description)
    {
        // The Ast of a scriptblock literal has its offsets into the original
        // script and includes the braces, parse the text it actually contains
        // so the offsets match it.
        string text = scriptBlock.ToString();
        ScriptBlockAst ast = Parser.ParseInput(text, out _, out ParseError[] errors);
        if (errors.Length > 0)
        {
            throw new ArgumentException($"Failed to parse the {description}: {errors[0].Message}");
        }

        // A function's scriptblock, like ${function:Get-Thing}, has the text of
        // its body. Inline parameters, function Get-Thing($Name) { }, are
        // added as a param block so they need nothing extra. A dynamicparam
        // block adds parameters the remote function doesn't know about.
        if (ast.DynamicParamBlock is not null)
        {
            throw new ArgumentException(
                $"The {description} has a dynamicparam block, the remote function only has the parameters of its " +
                "param block.");
        }

        (string paramBlock, bool isAdvanced) = GetParamBlock(text, ast);

        // A filter's body runs for each pipeline input, its text is only the
        // body so it is put in a process block. Invoked on the client, the
        // filter's own scriptblock already runs that way.
        if (scriptBlock.Ast is FunctionDefinitionAst { IsFilter: true })
        {
            if (ast.BeginBlock is not null || ast.ProcessBlock is not null)
            {
                throw new ArgumentException(
                    $"The {description} is a filter with begin or process blocks, define it as a function instead.");
            }

            int bodyStart = ast.ParamBlock?.Extent.EndOffset ?? 0;
            text = $"{text.Substring(0, bodyStart)}\nprocess {{\n{text.Substring(bodyStart)}\n}}";
        }

        Hashtable usingValues;
        if (usingState is null)
        {
            if (ast.Find(a => a is UsingExpressionAst, true) is UsingExpressionAst usingAst)
            {
                throw new ArgumentException(
                    $"The {description} uses '{usingAst}' but it runs on the client where $using: is not supported. " +
                    "Use the variable directly, or call .GetNewClosure() on the scriptblock to capture the " +
                    "variables of a function.");
            }
            usingValues = [];
        }
        else
        {
            usingValues = GetUsingParameters(usingState, ast, description);
        }

        return new(text, paramBlock, isAdvanced, usingValues);
    }

    /// <summary>Gets the param block of the remote function that runs a script.</summary>
    /// <remarks>
    /// The remote function is an advanced function so it can stream pipeline input to the script and write errors
    /// as itself. The param block of an advanced script is used as is. Otherwise the parameters get a position, as
    /// they are positional in a script that isn't advanced, and two parameters are added: __ExtInputObject takes the
    /// pipeline input and __ExtArgumentList the arguments that aren't bound to a parameter, the script's $args.
    /// </remarks>
    internal static (string ParamBlock, bool IsAdvanced) GetParamBlock(string text, ScriptBlockAst ast)
    {
        ParamBlockAst? paramBlock = ast.ParamBlock;
        if (paramBlock is not null && IsAdvanced(paramBlock))
        {
            return (text.Substring(0, paramBlock.Extent.EndOffset), true);
        }

        StringBuilder sb = new();
        if (paramBlock is not null)
        {
            // Any comment based help before it. The param block's extent
            // starts after its attributes, they are kept from the text
            // before it too.
            sb.Append(text, 0, paramBlock.Extent.StartOffset).Append('\n');
        }

        sb.Append("[CmdletBinding()]\nparam (\n");
        int position = 0;
        foreach (ParameterAst parameter in (IEnumerable<ParameterAst>?)paramBlock?.Parameters ?? [])
        {
            // A switch isn't positional.
            sb.Append(parameter.StaticType == typeof(SwitchParameter)
                ? "    [Parameter()]\n"
                : $"    [Parameter(Position = {position++})]\n");
            sb.Append("    ").Append(parameter.Extent.Text).Append(",\n\n");
        }
        sb.Append("    [Parameter(ValueFromPipeline, DontShow)]\n    $__ExtInputObject,\n\n");
        sb.Append("    [Parameter(ValueFromRemainingArguments, DontShow)]\n    $__ExtArgumentList\n)");

        return (sb.ToString(), false);
    }

    private static bool IsAdvanced(ParamBlockAst paramBlock)
    {
        foreach (AttributeAst attribute in paramBlock.Attributes)
        {
            if (attribute.TypeName.GetReflectionAttributeType() == typeof(CmdletBindingAttribute))
            {
                return true;
            }
        }

        foreach (ParameterAst parameter in paramBlock.Parameters)
        {
            foreach (AttributeBaseAst attribute in parameter.Attributes)
            {
                if (attribute is AttributeAst attributeAst &&
                    attributeAst.TypeName.GetReflectionAttributeType() == typeof(ParameterAttribute))
                {
                    return true;
                }
            }
        }

        return false;
    }

    /// <summary>
    /// Gets the values of every $using: expression in the Ast from the session state. The resulting Hashtable is
    /// keyed the way PowerShell expects for the --% using parameter of a script invocation.
    /// </summary>
    private static Hashtable GetUsingParameters(SessionState sessionState, Ast ast, string description)
    {
        Hashtable found = new();
        HashSet<string> undefinedKeys = [];
        List<string> undefined = [];

        foreach (Ast usingStatement in ast.FindAll(a => a is UsingExpressionAst, true))
        {
            UsingExpressionAst usingAst = (UsingExpressionAst)usingStatement;
            VariableExpressionAst backingVariableAst = UsingExpressionAst.ExtractUsingVariable(usingAst);
            string varPath = backingVariableAst.VariablePath.UserPath;

            // PowerShell lowercases the key of a plain $using:var so it matches regardless of case. An index or
            // member expression is left as is as a string index could be case sensitive.
            string varText = usingAst.ToString();
            if (usingAst.SubExpression is VariableExpressionAst)
            {
                varText = varText.ToLowerInvariant();
            }
            string key = Convert.ToBase64String(Encoding.Unicode.GetBytes(varText));

            if (found.ContainsKey(key) || undefinedKeys.Contains(key))
            {
                continue;
            }

            // GetValue returns the default for a variable set to $null so a plain variable is looked up with Get.
            // A drive qualified path like env:VAR is not a variable and is only reachable through GetValue.
            object? value = UndefinedValue.Value;
            if (backingVariableAst.VariablePath.IsVariable)
            {
                PSVariable? variable = sessionState.PSVariable.Get(varPath);
                if (variable is not null)
                {
                    value = variable.Value;
                }
            }
            else
            {
                value = sessionState.PSVariable.GetValue(varPath, UndefinedValue.Value);
            }

            if (value is UndefinedValue)
            {
                undefinedKeys.Add(key);
                undefined.Add(usingAst.ToString());
                continue;
            }

            found.Add(key, ExtractUsingExpressionValue(value, usingAst.SubExpression));
        }

        if (undefined.Count > 0)
        {
            string varList = string.Join(", ", undefined.Select(v => $"'{v}'"));
            throw new ArgumentException(
                $"The value of the using variable(s) {varList} in the {description} cannot be retrieved because " +
                "they have not been set in the local session.");
        }

        return found;
    }

    private static object? ExtractUsingExpressionValue(object? value, ExpressionAst ast)
    {
        if (ast is not MemberExpressionAst && ast is not IndexExpressionAst)
        {
            return value;
        }

        // Rebuilds the member and index expressions on top of the variable value as a constant, from the innermost
        // variable outwards, and runs that to get the final value.
        VariableExpressionAst usingVariable = (VariableExpressionAst)ast.Find(a => a is VariableExpressionAst, false);
        ExpressionAst lookupAst = new ConstantExpressionAst(ast.Extent, value);
        ExpressionAst currentAst = usingVariable;
        while (true)
        {
            if (currentAst.Parent is IndexExpressionAst indexAst)
            {
#if NET
                lookupAst = new IndexExpressionAst(
                    indexAst.Extent,
                    lookupAst,
                    (ExpressionAst)indexAst.Index.Copy(),
                    indexAst.NullConditional);
#else
                lookupAst = new IndexExpressionAst(
                    indexAst.Extent,
                    lookupAst,
                    (ExpressionAst)indexAst.Index.Copy());
#endif
                currentAst = indexAst;
            }
            else if (currentAst.Parent is MemberExpressionAst memberAst)
            {
#if NET
                lookupAst = new MemberExpressionAst(
                    memberAst.Extent,
                    lookupAst,
                    (ExpressionAst)memberAst.Member.Copy(),
                    memberAst.Static,
                    memberAst.NullConditional);
#else
                lookupAst = new MemberExpressionAst(
                    memberAst.Extent,
                    lookupAst,
                    (ExpressionAst)memberAst.Member.Copy(),
                    memberAst.Static);
#endif
                currentAst = memberAst;
            }
            else
            {
                break;
            }
        }

        // Wrapping it in an array, like the unary comma, stops the pipeline from enumerating a collection value.
        lookupAst = new ArrayLiteralAst(ast.Extent, [lookupAst]);
        ScriptBlock extractionScriptBlock = new ScriptBlockAst(
            ast.Extent,
            null,
            new StatementBlockAst(
                ast.Extent,
                [
                    new PipelineAst(
                        ast.Extent,
                        [new CommandExpressionAst(ast.Extent, lookupAst, null)])
                ],
                null),
            false).GetScriptBlock();

        return extractionScriptBlock.Invoke()[0];
    }
}
