using System.Collections;
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

#if !NET
using System;
using System.Reflection;
#endif

namespace RemoteWrench.Ext;

/// <summary>Runs a nested pipeline in a runspace.</summary>
internal static class NestedPipeline
{
#if !NET
    private static readonly MethodInfo s_createNestedPipeline = typeof(Runspace).GetMethod(
        "CreateNestedPipeline",
        [typeof(string), typeof(bool)])
        ?? throw new MissingMethodException(typeof(Runspace).FullName, "CreateNestedPipeline");
#endif

    /// <summary>Runs the script as a nested pipeline with the input.</summary>
    /// <param name="runspace">The runspace to run it in.</param>
    /// <param name="script">The script to run.</param>
    /// <param name="input">The input objects.</param>
    /// <param name="output">The output of the pipeline.</param>
    /// <returns>The first error the pipeline wrote, or null if there were none.</returns>
    public static object? Invoke(Runspace runspace, string script, IEnumerable input, out Collection<PSObject> output)
    {
#if NET
        using Pipeline pipeline = runspace.CreateNestedPipeline(script, false);
        output = pipeline.Invoke(input);
        return pipeline.Error.Count > 0 ? pipeline.Error.Read() : null;
#else
        // The Windows PowerShell reference assembly has no Pipeline type, it
        // exists at runtime.
        object pipeline = s_createNestedPipeline.Invoke(runspace, [script, false]);
        try
        {
            Type pipelineType = pipeline.GetType();
            try
            {
                output = (Collection<PSObject>)pipelineType.GetMethod("Invoke", [typeof(IEnumerable)])!
                    .Invoke(pipeline, [input]);
            }
            catch (TargetInvocationException e) when (e.InnerException is not null)
            {
                throw e.InnerException;
            }

            object reader = pipelineType.GetProperty("Error")!.GetValue(pipeline);
            Type readerType = reader.GetType();
            int count = (int)readerType.GetProperty("Count")!.GetValue(reader);
            return count > 0 ? readerType.GetMethod("Read", Type.EmptyTypes)!.Invoke(reader, []) : null;
        }
        finally
        {
            ((IDisposable)pipeline).Dispose();
        }
#endif
    }
}
