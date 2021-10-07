# K6 LoadTest Automation - DevOps Conf 2021

This repo is a demo for the integration of k6 loadtesting in GitHub and Azure DevOps, using both native k6 actions and custom scripts for leveraging Azure Cloud.

## The APIs

There is a [demo API project](./src/TestApi), using minimal API available in .NET 6 preview. This APIs offers a 'Hello World' endpoint (BASE_URL/fastapi). For demo pursposes, we'll try to deploy a second endponit (BASE_URL/slowapi) which has a ```Thread.Sleep(1000)``` to force a negative result in the load tests.

## CI/CD

The pipeline builds the project and deploys it to a staging environment on Azure. Then it uses k6 to laod test the APIs and if the set thresholds are satisfied, it swaps the slots.